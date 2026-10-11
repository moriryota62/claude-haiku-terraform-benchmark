terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30"
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
  default     = "dbadmin"
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
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    a = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 0)
      az   = local.azs[0]
    }
    b = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 1)
      az   = local.azs[1]
    }
  }

  private_subnets = {
    a = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 10)
      az   = local.azs[0]
    }
    b = {
      cidr = cidrsubnet(var.vpc_cidr, 8, 11)
      az   = local.azs[1]
    }
  }

  log_group_name = "/haiku-benchmark/app"
}

# ---------------------------------------------------------------
# Network
# ---------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-vpc"
  })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-public-${each.key}"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-private-${each.key}"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-igw"
  })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-nat-eip"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-nat"
  })

  depends_on = [aws_internet_gateway.main]
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

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-private-rt"
  })
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

# ---------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "haiku-benchmark-alb-"
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
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "haiku-benchmark-app-"
  description = "Security group for ASG instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-app-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "haiku-benchmark-db-"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from ASG instances"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------
# IAM
# ---------------------------------------------------------------
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
      "${aws_cloudwatch_log_group.app.arn}:*",
    ]
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = 30

  tags = local.common_tags
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "haiku-benchmark-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name_prefix = "haiku-benchmark-cwlogs-"
  description = "Allow EC2 instances to write to the application log group"
  policy      = data.aws_iam_policy_document.cloudwatch_logs.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_logs" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "haiku-benchmark-ec2-"
  role        = aws_iam_role.ec2.name

  tags = local.common_tags
}

# ---------------------------------------------------------------
# ALB
# ---------------------------------------------------------------
resource "aws_lb" "main" {
  name_prefix        = "hb-"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb"
  })
}

resource "aws_lb_target_group" "app" {
  name_prefix = "hb-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

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

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-tg"
  })

  lifecycle {
    create_before_destroy = true
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

  tags = local.common_tags
}

# ---------------------------------------------------------------
# Launch Template / ASG
# ---------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "haiku-benchmark-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    dnf install -y httpd
    echo "haiku-benchmark" > /var/www/html/index.html
    systemctl enable --now httpd
  EOT
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

  tags = local.common_tags
}

resource "aws_autoscaling_group" "app" {
  name_prefix         = "haiku-benchmark-app-"
  desired_capacity    = 2
  min_size            = 1
  max_size            = 3
  vpc_zone_identifier = [for s in aws_subnet.private : s.id]
  target_group_arns   = [aws_lb_target_group.app.arn]
  health_check_type   = "ELB"

  health_check_grace_period = 120

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

  depends_on = [aws_nat_gateway.main]
}

# ---------------------------------------------------------------
# RDS
# ---------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name_prefix = "haiku-benchmark-"
  subnet_ids  = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-subnet-group"
  })
}

resource "aws_db_instance" "main" {
  identifier_prefix = "haiku-benchmark-"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  port     = 3306

  # Master password is generated and stored in AWS Secrets Manager
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-mysql"
  })
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "Endpoint of the RDS instance (contains no credentials)"
  value       = aws_db_instance.main.endpoint
}
