terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for VPC"
  default     = "10.0.0.0/16"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR block allowed for SSH access"
  default     = "10.0.0.0/8"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.micro"
}

variable "project_name" {
  type        = string
  description = "Project name for tagging"
  default     = "haiku-benchmark"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "main-vpc"
    Project = var.project_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "main-igw"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  for_each = {
    "public_1a" = {
      cidr_block            = "10.0.1.0/24"
      availability_zone_idx = 0
    }
    "public_1c" = {
      cidr_block            = "10.0.2.0/24"
      availability_zone_idx = 1
    }
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr_block
  availability_zone       = data.aws_availability_zones.available.names[each.value.availability_zone_idx]
  map_public_ip_on_launch = true

  tags = {
    Name    = each.key
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2" {
  name_prefix = "ec2-sg-"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "ec2-sg"
    Project = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public["public_1a"].id
  vpc_security_group_ids = [aws_security_group.ec2.id]

  tags = {
    Name    = "main-instance"
    Project = var.project_name
  }
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "subnet_ids" {
  description = "List of public subnet IDs"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "ec2_public_ip" {
  description = "Public IP address of EC2 instance"
  value       = aws_instance.main.public_ip
}
