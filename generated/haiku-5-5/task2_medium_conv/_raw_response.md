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
  description = "パブリックサブネットのCIDRブロックのリスト(異なるAZに2つ作成される)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "public_subnet_cidrs には2つのCIDRを指定してください。"
  }
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  description = "SSH(22番)接続を許可するCIDRのリスト。デフォルトは安全側としてVPC内部のみ許可。実際の接続元IP(例: 203.0.113.10/32)を指定してください。"
  default     = ["10.0.0.0/16"]
}

variable "instance_type" {
  type        = string
  description = "EC2インスタンスタイプ"
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
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  # AZ名をキーとしたパブリックサブネットのCIDRマップを作成
  public_subnets = {
    for idx, cidr in var.public_subnet_cidrs :
    data.aws_availability_zones.available.names[idx] => cidr
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "haiku-benchmark-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "haiku-benchmark-public-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-public-rt"
  }
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

resource "aws_security_group" "ec2" {
  name        = "haiku-benchmark-ec2-sg"
  description = "Security group for haiku-benchmark EC2 instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-ec2-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "SSH from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP from anywhere"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound traffic"
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = values(aws_subnet.public)[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]

  tags = {
    Name = "haiku-benchmark-ec2"
  }
}
```

# ファイル名: outputs.tf

```hcl
output "vpc_id" {
  description = "作成したVPCのID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "作成したパブリックサブネットのIDの一覧"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "ec2_public_ip" {
  description = "EC2インスタンスのパブリックIPアドレス"
  value       = aws_instance.web.public_ip
}
```