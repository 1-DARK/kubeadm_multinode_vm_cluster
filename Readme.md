# Kubernetes Cluster on AWS

This guide builds a **3-node Kubernetes cluster** on AWS.

You use **Terraform** on your laptop to create the EC2 machines. Then you SSH into those machines and install Kubernetes with **kubeadm**.

| Tool | What it does in this lab |
|------|--------------------------|
| Terraform | Creates the EC2 instances and security groups |
| kubeadm | Bootstraps the Kubernetes control plane and joins workers |
| containerd | Container runtime that actually starts containers |
| Calico | Pod network so pods on different nodes can talk |
| kubectl | CLI you run on the master (and on workers after you copy kubeconfig) to manage the cluster |

## What you will have

```text
Your laptop  →  Terraform + SSH
                    │
                    ▼
AWS
├── master     control plane (API server, etcd, scheduler)
├── worker01   runs your application pods
└── worker02   runs your application pods
```

- **Master** is the manager. You run `kubeadm init` and most `kubectl` commands here.
- **Workers** only join the cluster and run workloads. Do not run `kubeadm init` on them.

AWS bills for running instances. When you are done, run `terraform destroy` from the same folder you used to apply.

## Before you start

On **your laptop**:

- An AWS account and credentials Terraform can use
- Terraform installed
- An SSH key pair, with the `.pem` (or private key) on your laptop
- A terminal

You will copy values from Terraform output into later commands:

| Placeholder | Meaning | Where you get it |
|-------------|---------|------------------|
| `your-key.pem` | Path to your private SSH key | Your machine |
| `SERVER_PUBLIC_IP` | Public IP of that EC2 instance | Terraform output / AWS console |
| `MASTER_PRIVATE_IP` | **Private** IP of the master | Master: `hostname -I` or AWS console |
| `TOKEN` and `HASH` | Join credentials | Printed by `kubeadm init` (or `kubeadm token create`) |

Workers must join using the master's **private** IP on port **6443**. Security groups must allow that traffic between nodes.

## Steps

### 1. Create the EC2 machines (laptop)

Run this on **your laptop**, not on AWS yet.

```bash
git clone https://github.com/1-DARK/kubeadm_multinode_vm_cluster.git
cd kubeadm_multinode_vm_cluster

terraform init
terraform apply
```

Type `yes` when asked.

Terraform should create:

- 1 master EC2
- 2 worker EC2 (`worker01`, `worker02`)
- Security groups for SSH and Kubernetes traffic

Note each instance's **public IP** (for SSH) and the master's **private IP** (for `kubeadm`).

### 2. SSH into every node (laptop)

Open **three terminals** (or reconnect one at a time). From your laptop:

```bash
ssh -i your-key.pem ubuntu@SERVER_PUBLIC_IP
```

Replace `your-key.pem` and `SERVER_PUBLIC_IP` for master, then worker01, then worker02.

If the key is too open, SSH may refuse it:

```bash
chmod 400 your-key.pem
```

Stay logged in. The next section runs **inside** those SSH sessions.

### 3. Prepare all 3 servers (master + both workers)

Kubernetes needs the same base setup on every node: no swap, kernel networking for pods, containerd, and matching kubeadm/kubelet versions.

Run **every command in this section on all three machines**.

**Disable swap.** kubelet will not run reliably with swap on.

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Load kernel modules** used by overlay networks and bridges.

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
```

**Enable packet forwarding** so pods can route through the node.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

**Install containerd, runc, and CNI plugins.** These are the runtime stack under kubelet.

```bash
curl -LO https://github.com/containerd/containerd/releases/download/v1.7.14/containerd-1.7.14-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.7.14-linux-amd64.tar.gz

curl -LO https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo mkdir -p /usr/local/lib/systemd/system/
sudo mv containerd.service /usr/local/lib/systemd/system/

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd

curl -LO https://github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

curl -LO https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-amd64-v1.5.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.5.0.tgz
```

**Install kubeadm, kubelet, and kubectl** at a pinned 1.29 version so all nodes match.

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update

sudo apt-get install -y \
kubelet=1.29.6-1.1 \
kubeadm=1.29.6-1.1 \
kubectl=1.29.6-1.1 \
--allow-downgrades \
--allow-change-held-packages

sudo apt-mark hold kubelet kubeadm kubectl
```

`apt-mark hold` stops `apt upgrade` from silently changing Kubernetes versions.

Point **crictl** at containerd so you can debug containers later:

```bash
sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
```

### 4. Initialize the control plane (master only)

On the **master**, find the private IP (example: `ip -4 addr show` or `hostname -I`). Use that value as `MASTER_PRIVATE_IP`.

`--pod-network-cidr=192.168.0.0/16` must match Calico's default in the next step. `--apiserver-advertise-address` is how workers reach the API server.

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=MASTER_PRIVATE_IP \
  --node-name master
```

When it finishes, copy the **`kubeadm join ...`** line. You need it for the workers. Treat the token like a secret.

Then configure `kubectl` for the `ubuntu` user on the master (root already has the admin file under `/etc/kubernetes`):

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Install **Calico** so the CNI exists. Until this works, nodes often stay `NotReady` and pods cannot network.

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

curl https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml -O
kubectl apply -f custom-resources.yaml
```

### 5. Join the workers (worker01 and worker02 only)

On **each worker**, paste the join command from step 4. It looks like this (your token and hash will differ):

```bash
sudo kubeadm join MASTER_PRIVATE_IP:6443 \
  --token TOKEN \
  --discovery-token-ca-cert-hash sha256:HASH
```

If you lost the command, on the **master**:

```bash
kubeadm token create --print-join-command
```

Run that printed command on each worker.

### 6. Confirm the cluster (master)

On the **master**:

```bash
kubectl get nodes
```

You want all three `Ready`. Calico can take a minute or two.

```text
master     Ready
worker01   Ready
worker02   Ready
```

If a node is `NotReady`, check `kubectl get pods -n calico-system` and the troubleshooting table below.

### 7. Use kubectl from the worker nodes

After the cluster is confirmed on the master, copy the admin kubeconfig onto each worker so `kubectl` works there too.

**On the master**, print the file and copy **all** of it:

```bash
cat $HOME/.kube/config
```

**On each worker** (`worker01` and `worker02`):

```bash
mkdir -p /home/ubuntu/.kube
```

Create `/home/ubuntu/.kube/config` and paste the copied data into that file (for example with `nano /home/ubuntu/.kube/config`). Then:

```bash
sudo chmod 775 /home/ubuntu/.kube/config
```

On the **worker**, confirm kubectl can talk to the API:

```bash
kubectl get nodes
```

You should see the same node list as on the master (master, worker01, worker02).

Treat this file like a secret. It is cluster-admin access.

### 8. Deploy a test app (master)

Still on the **master**. This creates 3 nginx pods and a NodePort Service so you can reach them from a node IP.

```bash
kubectl create deployment nginx --image=nginx
kubectl scale deployment nginx --replicas=3
kubectl expose deployment nginx --type=NodePort --port=80

kubectl get pods -o wide
kubectl get svc
```

`-o wide` shows which node each pod landed on. `kubectl get svc` shows the NodePort (high port, often in the 30000–32767 range).

### 9. Tear down (laptop)

When you are finished, from the **Terraform project folder on your laptop**:

```bash
terraform destroy
```

Type `yes`. This deletes the EC2 instances so you stop paying for them.

## Troubleshooting

| Problem | What it usually means | What to do |
|--------|------------------------|------------|
| Nodes stay `NotReady` | CNI not ready, or kubelet cannot talk to the API | Confirm Calico pods are running; check security groups for 6443 and node-to-node traffic |
| Calico fails on AWS | Source/destination checks block overlay routing | On each instance in the EC2 console: disable **source/destination check** |
| Calico picks the wrong NIC | AWS nodes often have more than one interface | On master: `kubectl set env daemonset/calico-node -n calico-system IP_AUTODETECTION_METHOD=interface=ens5` — replace `ens5` with the real interface (`ip link`) |
| Join command expired or lost | Bootstrap tokens expire | On master: `kubeadm token create --print-join-command` |
| SSH permission denied | Wrong key, user, or IP | User is `ubuntu`; use the **public** IP; `chmod 400` the key |


