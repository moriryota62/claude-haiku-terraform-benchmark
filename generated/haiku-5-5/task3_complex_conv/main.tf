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

variable "name_prefix" {
  type        = string
  description = "リソース名のプレフィックス"
  default     = "haiku-benchmark"
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
  description = "RDSの初期データベース名"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "RDSのマスターユーザー名"
  default     = "admin"
}

variable "db_password" {
  type        = string
  description = "RDSのマスターパスワード(実行時に指定し、コードには記述しない)"
  sensitive   = true
}

# ------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

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
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i)
  }

  private_subnets = {
    for i, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, i + 10)
  }
}

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.name_prefix}-nat"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------------
# Security Groups
# ------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from anywhere"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Security group for ASG instances"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Allow HTTP from ALB only"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound via NAT"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Allow MySQL from ASG instances only"
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------------------------------------
# Application Load Balancer
# ------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------------------------------------------
# IAM
# ------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_cloudwatch_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name_prefix}/*",
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name_prefix}/*:log-stream:*",
    ]
  }
}

resource "aws_iam_role_policy" "ec2_cloudwatch_logs" {
  name   = "${var.name_prefix}-cloudwatch-logs"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_cloudwatch_logs.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ------------------------------------------------------------
# Auto Scaling Group
# ------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y httpd
    systemctl enable --now httpd
    echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "${var.name_prefix}-app"
      Project = "haiku-benchmark"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name    = "${var.name_prefix}-app-volume"
      Project = "haiku-benchmark"
    }
  }

  tags = {
    Name = "${var.name_prefix}-lt"
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.name_prefix}-asg"
  desired_capacity          = 2
  min_size                  = 1
  max_size                  = 3
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "haiku-benchmark"
    propagate_at_launch = true
  }
}

# ------------------------------------------------------------
# RDS
# ------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.name_prefix}-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  multi_az               = false
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

output "alb_dns_name" {
  description = "ALBのDNS名"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDSのエンドポイント(ホスト名:ポート)"
  value       = aws_db_instance.main.endpoint
}

output "vpc_id" {
  description = "VPCのID"
  value       = aws_vpc.main.id
}
