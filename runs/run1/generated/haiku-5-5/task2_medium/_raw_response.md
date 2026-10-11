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

  default_tags {
    tags = {
      Project = "haiku-benchmark"
    }
  }
}
```

# ファイル名: variables.tf

```hcl
variable "aws_region" {
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
  description = "パブリックサブネットのCIDRブロック一覧(異なるAZに2つ作成される)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "public_subnet_cidrs は2つのCIDRを指定してください。"
  }
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "SSH(22番)接続を許可するCIDRの一覧。デフォルトはVPC内のみ。接続元のグローバルIPを /32 で指定することを推奨。0.0.0.0/0 は指定不可。"
  default     = ["10.0.0.0/16"]

  validation {
    condition     = alltrue([for c in var.allowed_ssh_cidrs : c != "0.0.0.0/0"])
    error_message = "allowed_ssh_cidrs に 0.0.0.0/0 は指定できません。接続元のIPを指定してください。"
  }
}

variable "instance_type" {
  type        = string
  description = "EC2インスタンスのタイプ"
  default     = "t3.micro"
}
```

# ファイル名: main.tf

```hcl
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
    name   = "state"
    values = ["available"]
  }
}

locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  # キー: AZ名, 値: CIDR
  public_subnets = {
    for i, cidr in var.public_subnet_cidrs :
    data.aws_availability_zones.available.names[i] => cidr
  }

  ec2_az = data.aws_availability_zones.available.names[0]
}

# ---------------------------------------------------------------
# VPC / IGW / Subnets / Route Table
# ---------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-${each.key}"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "haiku-benchmark-ec2-sg"
  description = "Security group for haiku-benchmark EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ssh-${replace(each.value, "/", "_")}"
  })
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.ec2.id
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
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-egress-all"
  })
}

# ---------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[local.ec2_az].id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2"
  })
}
```

# ファイル名: outputs.tf

```hcl
output "vpc_id" {
  description = "作成されたVPCのID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "作成されたパブリックサブネットのID一覧"
  value       = [for s in aws_subnet.public : s.id]
}

output "ec2_public_ip" {
  description = "EC2インスタンスのパブリックIPアドレス"
  value       = aws_instance.app.public_ip
}
```