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
    tags = local.common_tags
  }
}

variable "region" {
  type        = string
  description = "AWS region to deploy resources into"
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the Auto Scaling Group"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "Name of the initial database"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "Master username for the RDS instance (the password is managed by AWS Secrets Manager)"
  default     = "admin"
}

locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  public_subnets = {
    a = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 0)
      az   = data.aws_availability_zones.available.names[0]
    }
    b = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 1)
      az   = data.aws_availability_zones.available.names[1]
    }
  }

  private_subnets = {
    a = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 10)
      az   = data.aws_availability_zones.available.names[0]
    }
    b = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 11)
      az   = data.aws_availability_zones.available.names[1]
    }
  }
}

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

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

################################################################################
# Network
################################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "haiku-benchmark-main"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "haiku-benchmark-public-${each.key}"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "haiku-benchmark-private-${each.key}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-main"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "haiku-benchmark-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  tags = {
    Name = "haiku-benchmark-main"
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
    Name = "haiku-benchmark-public"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "haiku-benchmark-private"
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

################################################################################
# Security Groups
################################################################################

resource "aws_security_group" "alb" {
  name        = "haiku-benchmark-alb"
  description = "Security group for the ALB"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-alb"
  }
}

resource "aws_security_group" "web" {
  name        = "haiku-benchmark-web"
  description = "Security group for the ASG instances"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-web"
  }
}

resource "aws_security_group" "db" {
  name        = "haiku-benchmark-db"
  description = "Security group for the RDS instance"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "haiku-benchmark-db"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to ASG instances"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "web_http_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "HTTP from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS to internet via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP to internet via NAT (package repositories)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "web_to_db" {
  security_group_id            = aws_security_group.web.id
  description                  = "MySQL to RDS"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_mysql_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from ASG instances"
  referenced_security_group_id = aws_security_group.web.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

################################################################################
# IAM
################################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/haiku-benchmark/app"
  retention_in_days = 30
}

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

data "aws_iam_policy_document" "cloudwatch_logs" {
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

resource "aws_iam_role" "ec2" {
  name               = "haiku-benchmark-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name        = "haiku-benchmark-cloudwatch-logs"
  description = "Allow EC2 instances to write to the application log group"
  policy      = data.aws_iam_policy_document.cloudwatch_logs.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "haiku-benchmark-ec2"
  role = aws_iam_role.ec2.name
}

################################################################################
# ALB
################################################################################

resource "aws_lb" "app" {
  name                       = "haiku-benchmark-app"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = [for s in aws_subnet.public : s.id]
  drop_invalid_header_fields = true

  tags = {
    Name = "haiku-benchmark-app"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "haiku-benchmark-app"
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
    Name = "haiku-benchmark-app"
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
}

################################################################################
# Launch Template / ASG
################################################################################

resource "aws_launch_template" "app" {
  name_prefix   = "haiku-benchmark-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.web.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    echo "haiku-benchmark" > /var/www/html/index.html
    systemctl enable --now httpd
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "haiku-benchmark-app"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  tags = {
    Name = "haiku-benchmark-app"
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "haiku-benchmark-app"
  desired_capacity          = 2
  min_size                  = 1
  max_size                  = 3
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  tag {
    key                 = "Project"
    value               = "haiku-benchmark"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = "haiku-benchmark-app"
    propagate_at_launch = true
  }
}

################################################################################
# RDS
################################################################################

resource "aws_db_subnet_group" "main" {
  name       = "haiku-benchmark-main"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = {
    Name = "haiku-benchmark-main"
  }
}

resource "aws_db_instance" "main" {
  identifier        = "haiku-benchmark-main"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  port     = 3306

  # パスワードはAWS Secrets Managerで自動管理される
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Name = "haiku-benchmark-main"
  }
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "rds_endpoint" {
  description = "RDS endpoint address (hostname only, no credentials)"
  value       = aws_db_instance.main.address
}
