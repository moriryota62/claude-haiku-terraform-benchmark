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

variable "instance_type" {
  type        = string
  description = "ASGで起動するEC2のインスタンスタイプ"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "RDSのインスタンスクラス"
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  type        = string
  description = "RDS MySQLのエンジンバージョン"
  default     = "8.0"
}

variable "db_allocated_storage" {
  type        = number
  description = "RDSの割り当てストレージ(GB)"
  default     = 20
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

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logsの保持日数"
  default     = 14
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
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  subnet_indexes = {
    a = 0
    b = 1
  }

  public_subnets = {
    for key, idx in local.subnet_indexes : key => {
      az   = data.aws_availability_zones.available.names[idx]
      cidr = cidrsubnet(var.vpc_cidr, 8, idx)
    }
  }

  private_subnets = {
    for key, idx in local.subnet_indexes : key => {
      az   = data.aws_availability_zones.available.names[idx]
      cidr = cidrsubnet(var.vpc_cidr, 8, idx + 10)
    }
  }
}

################################
# Network
################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "haiku-main"
    Project = "haiku-benchmark"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "haiku-main"
    Project = "haiku-benchmark"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name    = "haiku-public-${each.key}"
    Project = "haiku-benchmark"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name    = "haiku-private-${each.key}"
    Project = "haiku-benchmark"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name    = "haiku-nat"
    Project = "haiku-benchmark"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  tags = {
    Name    = "haiku-main"
    Project = "haiku-benchmark"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "haiku-public"
    Project = "haiku-benchmark"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name    = "haiku-private"
    Project = "haiku-benchmark"
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

################################
# Security Groups
################################
resource "aws_security_group" "alb" {
  name        = "haiku-alb"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "haiku-alb"
    Project = "haiku-benchmark"
  }
}

resource "aws_security_group" "app" {
  name        = "haiku-app"
  description = "Security group for application instances"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "haiku-app"
    Project = "haiku-benchmark"
  }
}

resource "aws_security_group" "db" {
  name        = "haiku-db"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "haiku-db"
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to application instances"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.app.id

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound (via NAT and to DB)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_mysql_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from application instances"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id

  tags = {
    Project = "haiku-benchmark"
  }
}

################################
# IAM
################################
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

resource "aws_cloudwatch_log_group" "app" {
  name              = "/haiku-benchmark/app"
  retention_in_days = var.log_retention_days

  tags = {
    Project = "haiku-benchmark"
  }
}

data "aws_iam_policy_document" "logs_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.app.arn,
      "${aws_cloudwatch_log_group.app.arn}:log-stream:*",
    ]
  }
}

resource "aws_iam_role" "app" {
  name               = "haiku-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_iam_policy" "logs_write" {
  name        = "haiku-app-logs-write"
  description = "Allow writing to the application CloudWatch log group"
  policy      = data.aws_iam_policy_document.logs_write.json

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_iam_role_policy_attachment" "logs_write" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.logs_write.arn
}

resource "aws_iam_instance_profile" "app" {
  name = "haiku-app"
  role = aws_iam_role.app.name

  tags = {
    Project = "haiku-benchmark"
  }
}

################################
# ALB
################################
resource "aws_lb" "app" {
  name               = "haiku-app"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  tags = {
    Name    = "haiku-app"
    Project = "haiku-benchmark"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "haiku-app"
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
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name    = "haiku-app"
    Project = "haiku-benchmark"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Project = "haiku-benchmark"
  }
}

################################
# Launch Template / ASG
################################
resource "aws_launch_template" "app" {
  name_prefix   = "haiku-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf install -y httpd
    systemctl enable --now httpd
    echo "haiku-benchmark" > /var/www/html/index.html
  EOT
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "haiku-app"
      Project = "haiku-benchmark"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name    = "haiku-app"
      Project = "haiku-benchmark"
    }
  }

  tags = {
    Project = "haiku-benchmark"
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "haiku-app"
  desired_capacity          = 2
  min_size                  = 1
  max_size                  = 3
  vpc_zone_identifier       = [for subnet in aws_subnet.private : subnet.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "haiku-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "haiku-benchmark"
    propagate_at_launch = true
  }

  depends_on = [aws_nat_gateway.main]
}

################################
# RDS
################################
resource "aws_db_subnet_group" "main" {
  name       = "haiku-main"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name    = "haiku-main"
    Project = "haiku-benchmark"
  }
}

resource "aws_db_instance" "main" {
  identifier        = "haiku-main"
  engine            = "mysql"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  port     = 3306

  # パスワードはAWS Secrets Managerで自動生成・管理される
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name    = "haiku-main"
    Project = "haiku-benchmark"
  }
}

output "alb_dns_name" {
  description = "ALBのDNS名"
  value       = aws_lb.app.dns_name
}

output "rds_endpoint" {
  description = "RDSのエンドポイント(ホスト名のみ。認証情報は含まない)"
  value       = aws_db_instance.main.address
}
