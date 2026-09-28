output "master_public_ip" {
  description = "Public IP of Kubernetes master"
  value       = aws_instance.master.public_ip
}

output "worker01_public_ip" {
  description = "Public IP of worker01"
  value       = aws_instance.worker01.public_ip
}

output "worker02_public_ip" {
  description = "Public IP of worker02"
  value       = aws_instance.worker02.public_ip
}

output "master_private_ip" {
  description = "Private IP of Kubernetes master"
  value       = aws_instance.master.private_ip
}

output "worker01_private_ip" {
  description = "Private IP of worker01"
  value       = aws_instance.worker01.private_ip
}

output "worker02_private_ip" {
  description = "Private IP of worker02"
  value       = aws_instance.worker02.private_ip
}
