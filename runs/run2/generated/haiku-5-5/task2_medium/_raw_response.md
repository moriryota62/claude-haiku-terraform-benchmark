# ファイル名: providers.tf

```hcl
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
  region = var.aws_region
}
```

# ファイル名: variables.tf

```hcl
variable "aws_region" {
  type        = string
  description = "AWSプロバイダのリージョン"
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  type        = string
  description = "VPCのCIDRブロック"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "パブリックサブネットのCIDRブロックのリスト（異なるAZに1つずつ作成される）"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "パブリックサブネットは2つ以上指定してください。"
  }
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "SSH(22番)接続を許可するCIDRのリスト（例: 自宅や事務所のIPを x.x.x.x/32 で指定）。デフォルトはVPC内部のみ"
  default     = ["10.0.0.0/16"]
}

variable "instance_type" {
  type        = string
  description = "EC2インスタンスのインスタンスタイプ"
  default     = "t3.micro"
}
```

# ファイル名: main.tf

```hcl
locals {
  common_tags = {
    Project = "haiku-benchmark"
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
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
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

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-igw"
  })
}

# パブリックサブネット（異なるAZに配置）
resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.available.names[tonumber(each.key)]
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
resource "aws_security_group" "web" {
  name        = "haiku-benchmark-web-sg"
  description = "Security group for haiku-benchmark EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-web-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.web.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ssh-${replace(each.value, "/", "-")}"
  })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-http"
  })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-egress-all"
  })
}

# EC2インスタンス（1つ目のパブリックサブネットに配置）
resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public["0"].id
  vpc_security_group_ids = [aws_security_group.web.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-web"
  })
}
```

# ファイル名: outputs.tf

```hcl
output "vpc_id" {
  description = "作成したVPCのID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "パブリックサブネットのIDの一覧"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "ec2_public_ip" {
  description = "EC2インスタンスのパブリックIPアドレス"
  value       = aws_instance.web.public_ip
}
```