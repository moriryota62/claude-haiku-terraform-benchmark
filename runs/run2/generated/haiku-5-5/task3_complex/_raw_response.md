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
  region = var.region

  default_tags {
    tags = {
      Project = "haiku-benchmark"
    }
  }
}
```

# ファイル名: variables.tf

```hcl
variable "region" {
  type        = string
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "project_name" {
  type        = string
  description = "リソース名のプレフィックスとして使用するプロジェクト名"
  default     = "haiku-benchmark"
}

variable "vpc_cidr" {
  type        = string
  description = "VPCのCIDRブロック"
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "ASG内EC2インスタンスのインスタンスタイプ"
  default     = "t3.micro"
}

variable "asg_desired_capacity" {
  type        = number
  description = "Auto Scaling Groupの希望インスタンス数"
  default     = 2
}

variable "asg_min_size" {
  type        = number
  description = "Auto Scaling Groupの最小インスタンス数"
  default     = 1
}

variable "asg_max_size" {
  type        = number
  description = "Auto Scaling Groupの最大インスタンス数"
  default     = 3
}

variable "db_engine_version" {
  type        = string
  description = "RDS MySQLのエンジンバージョン"
  default     = "8.0"
}

variable "db_instance_class" {
  type        = string
  description = "RDSインスタンスクラス"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "作成するデータベース名"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "RDSのマスターユーザー名"
  default     = "admin"
}

variable "db_password" {
  type        = string
  description = "RDSのマスターパスワード(実行時に環境変数 TF_VAR_db_password などで指定)"
  sensitive   = true
}
```

# ファイル名: main.tf

```hcl
############################################
# Data Sources
############################################

data "aws_availability_zones" "available" {
  state = "available"
}

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

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    for idx, az in local.azs : az => {
      cidr = cidrsubnet(var.vpc_cidr, 8, idx)
    }
  }

  private_subnets = {
    for idx, az in local.azs : az => {
      cidr = cidrsubnet(var.vpc_cidr, 8, idx + 10)
    }
  }

  cloudwatch_log_group_arn = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${var.project_name}*"
}

############################################
# Network
############################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.key

  tags = {
    Name = "${var.project_name}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = {
    Name = "${var.project_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-public-rt"
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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
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

############################################
# Security Groups
############################################

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP to VPC targets"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "asg" {
  name        = "${var.project_name}-asg-sg"
  description = "Security group for Auto Scaling instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-asg-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from ASG instances only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.asg.id]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

############################################
# IAM
############################################

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
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      local.cloudwatch_log_group_arn,
      "${local.cloudwatch_log_group_arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name   = "${var.project_name}-cloudwatch-logs"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.cloudwatch_logs.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

############################################
# Application Load Balancer
############################################

resource "aws_lb" "app" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-tg"
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
    Name = "${var.project_name}-tg"
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

############################################
# Auto Scaling Group
############################################

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.asg.id]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf install -y httpd
    echo "OK" > /var/www/html/index.html
    systemctl enable --now httpd
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-app"
      Project = "haiku-benchmark"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${var.project_name}-app-volume"
      Project = "haiku-benchmark"
    }
  }

  tags = {
    Name = "${var.project_name}-lt"
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.project_name}-asg"
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  desired_capacity          = var.asg_desired_capacity
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "haiku-benchmark"
    propagate_at_launch = true
  }
}

############################################
# RDS
############################################

resource "aws_db_subnet_group" "db" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-db"
  engine                 = "mysql"
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  backup_retention_period = 7

  tags = {
    Name = "${var.project_name}-db"
  }
}
```

# ファイル名: outputs.tf

```hcl
output "alb_dns_name" {
  description = "ApplicationLoad BalancerのDNS名"
  value       = aws_lb.app.dns_name
}

output "rds_endpoint" {
  description = "RDSのエンドポイント(ホスト名のみ、認証情報は含まない)"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDSのポート番号"
  value       = aws_db_instance.main.port
}

output "vpc_id" {
  description = "作成されたVPCのID"
  value       = aws_vpc.main.id
}
```