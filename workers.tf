resource "aws_instance" "worker01" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name


  vpc_security_group_ids = [
    aws_security_group.workersg.id
  ]

  tags = {
    Name = "worker01"
  }
}


resource "aws_instance" "worker02" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name


  vpc_security_group_ids = [
    aws_security_group.workersg.id
  ]

  tags = {
    Name = "worker02"
  }
}
