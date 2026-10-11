terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
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

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "パブリックサブネットのCIDRブロックのリスト(異なるAZに2つ作成される)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "public_subnet_cidrs には2つのCIDRを指定してください。"
  }
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "SSH(22番)接続を許可するCIDRのリスト。0.0.0.0/0は指定不可。"
  default     = ["10.0.0.0/16"]

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "セキュリティのため、allowed_ssh_cidrs に 0.0.0.0/0 は指定できません。接続元のIPを指定してください。"
  }
}

variable "instance_type" {
  type        = string
  description = "EC2インスタンスのタイプ"
  default     = "t3.micro"
}

locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  # AZ名をキーとしたパブリックサブネット定義
  public_subnets = {
    for idx, cidr in var.public_subnet_cidrs :
    data.aws_availability_zones.available.names[idx] => {
      cidr = cidr
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-vpc"
  })
}

# インターネットゲートウェイ
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-igw"
  })
}

# パブリックサブネット(異なるAZに作成)
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-${each.key}"
  })
}

# パブリック用ルートテーブル
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# EC2用セキュリティグループ
resource "aws_security_group" "ec2" {
  name        = "haiku-benchmark-ec2-sg"
  description = "Security group for haiku-benchmark EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2-sg"
  })
}

# SSH(22番): 許可されたCIDRごとにルールを作成
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.ec2.id
  description       = "SSH from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ssh-${replace(each.value, "/", "_")}"
  })
}

# HTTP(80番)
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-http"
  })
}

# アウトバウンド: 全許可
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-egress-all"
  })
}

# EC2インスタンス(パブリックサブネット, 先頭のサブネットに配置)
resource "aws_instance" "main" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = values(aws_subnet.public)[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]

  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2"
  })
}

output "vpc_id" {
  description = "作成したVPCのID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "作成したパブリックサブネットIDの一覧"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "ec2_public_ip" {
  description = "EC2インスタンスのパブリックIPアドレス"
  value       = aws_instance.main.public_ip
}
