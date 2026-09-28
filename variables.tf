variable "ami_id" {
  description = "AMI ID for Kubernetes nodes"
  type        = string
  default     = "ami-01a00762f46d584a1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "c7i-flex.large"
}

variable "key_name" {
  description = "Existing AWS EC2 key pair name"
  type        = string
  default     = "instancekey1"
}
