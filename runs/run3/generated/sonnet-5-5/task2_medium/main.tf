terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "haiku-benchmark"
    }
  }
}

variable "region" {
  type        = string
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  type        = string
  description = "VPCのCIDRブロック"
  default     = "10.0.0.0/16"
}

variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "SSH(22番)接続を許可するCIDRのリスト。デフォルトは空(SSH接続を許可しない)。0.0.0.0/0は指定不可"
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "ssh_allowed_cidrs に 0.0.0.0/0 を指定することはできません。"
  }
}

variable "instance_type" {
  type        = string
  description = "EC2インスタンスタイプ"
  default     = "t3.micro"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  public_subnets = {
    a = {
      cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
      availability_zone = data.aws_availability_zones.available.names[0]
    }
    b = {
      cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
      availability_zone = data.aws_availability_zones.available.names[1]
    }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "haiku-benchmark-vpc"
    Project = "haiku-benchmark"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name    = "haiku-benchmark-public-${each.key}"
    Project = "haiku-benchmark"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "haiku-benchmark-igw"
    Project = "haiku-benchmark"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "haiku-benchmark-public-rt"
    Project = "haiku-benchmark"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "haiku-benchmark-web-sg"
  description = "Security group for web EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "haiku-benchmark-web-sg"
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.web.id
  description       = "SSH from allowed CIDR"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value

  tags = {
    Name    = "haiku-benchmark-web-ssh"
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name    = "haiku-benchmark-web-http"
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name    = "haiku-benchmark-web-egress-all"
    Project = "haiku-benchmark"
  }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public["a"].id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name    = "haiku-benchmark-web"
    Project = "haiku-benchmark"
  }

  volume_tags = {
    Name    = "haiku-benchmark-web-root"
    Project = "haiku-benchmark"
  }

  depends_on = [aws_internet_gateway.main]
}

output "vpc_id" {
  description = "作成したVPCのID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDの一覧"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "instance_public_ip" {
  description = "EC2インスタンスのパブリックIP"
  value       = aws_instance.web.public_ip
}
