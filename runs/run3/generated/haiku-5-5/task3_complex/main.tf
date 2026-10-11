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

variable "instance_type" {
  type        = string
  description = "ASGで起動するEC2インスタンスタイプ"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "RDSインスタンスクラス"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "初期作成するデータベース名"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "RDSマスターユーザー名(パスワードはSecrets Managerで自動管理)"
  default     = "dbadmin"
}

variable "asg_desired_capacity" {
  type        = number
  description = "ASGの希望インスタンス数"
  default     = 2
}

variable "asg_min_size" {
  type        = number
  description = "ASGの最小インスタンス数"
  default     = 1
}

variable "asg_max_size" {
  type        = number
  description = "ASGの最大インスタンス数"
  default     = 3
}

locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  # 利用可能なAZのうち先頭2つを使用
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # サブネットCIDR: public は 0,1 番目 / private は 10,11 番目のブロック
  public_subnets = {
    for idx, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, idx)
  }

  private_subnets = {
    for idx, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, idx + 10)
  }

  user_data = <<-EOT
    #!/bin/bash
    set -eux
    dnf update -y
    dnf install -y nginx
    echo "<h1>haiku-benchmark: $(hostname)</h1>" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT
}

# ------------------------------------------------------------
# データソース
# ------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

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

# ------------------------------------------------------------
# ネットワーク
# ------------------------------------------------------------
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
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-nat-eip"
  })
}

# NATゲートウェイは1つのみ(パブリックサブネットの先頭に配置)
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-nat"
  })

  depends_on = [aws_internet_gateway.main]
}

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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-private-rt"
  })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------------
# セキュリティグループ
# ------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "haiku-benchmark-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app" {
  name        = "haiku-benchmark-app-sg"
  description = "ASG instances security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-app-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB only"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound (via NAT)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "haiku-benchmark-db-sg"
  description = "RDS security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from ASG instances only"
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------------------------------------
# ALB
# ------------------------------------------------------------
resource "aws_lb" "main" {
  name                       = "haiku-benchmark-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = [for s in aws_subnet.public : s.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb"
  })
}

resource "aws_lb_target_group" "app" {
  name     = "haiku-benchmark-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = local.common_tags
}

# ------------------------------------------------------------
# IAM (EC2インスタンス用)
# ------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "haiku-benchmark-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/haiku-benchmark/app"
  retention_in_days = 30

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ec2_cloudwatch_logs" {
  name = "haiku-benchmark-cloudwatch-logs"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteAppLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${aws_cloudwatch_log_group.app.name}:*"
      }
    ]
  })
}

# SSMによるセッションマネージャー接続用(AWS管理ポリシー)
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "haiku-benchmark-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = local.common_tags
}

# ------------------------------------------------------------
# Launch Template / Auto Scaling Group
# ------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "haiku-benchmark-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
  user_data     = base64encode(local.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "haiku-benchmark-app"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags         = local.common_tags
  }

  tags = local.common_tags
}

resource "aws_autoscaling_group" "app" {
  name                = "haiku-benchmark-asg"
  desired_capacity    = var.asg_desired_capacity
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  vpc_zone_identifier = [for s in aws_subnet.private : s.id]
  target_group_arns   = [aws_lb_target_group.app.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "haiku-benchmark-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "haiku-benchmark"
    propagate_at_launch = true
  }
}

# ------------------------------------------------------------
# RDS (MySQL)
# ------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "haiku-benchmark-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-subnet-group"
  })
}

resource "aws_db_instance" "main" {
  identifier     = "haiku-benchmark-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username

  # パスワードはRDSがSecrets Managerで生成・ローテーション管理する(コードに記述しない)
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  multi_az               = false
  publicly_accessible    = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  deletion_protection        = false
  skip_final_snapshot        = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db"
  })
}

output "alb_dns_name" {
  description = "ALBのDNS名(ブラウザ/curlでアクセスするエンドポイント)"
  value       = aws_lb.main.dns_name
}

output "rds_address" {
  description = "RDSインスタンスのホスト名(機密情報を含まない)"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDSインスタンスのポート番号"
  value       = aws_db_instance.main.port
}
