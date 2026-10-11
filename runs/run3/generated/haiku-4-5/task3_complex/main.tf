terraform {
  required_version = ">= 1.0"
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
  description = "AWS region"
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for VPC"
  default     = "10.0.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for ASG"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "Name of database"
  default     = "mydb"
}

variable "db_username" {
  type        = string
  description = "Master username for RDS"
  default     = "admin"
}

variable "db_password" {
  type        = string
  description = "Master password for RDS"
  sensitive   = true
}

variable "db_engine" {
  type        = string
  description = "RDS database engine"
  default     = "mysql"
  validation {
    condition     = contains(["mysql", "postgres"], var.db_engine)
    error_message = "db_engine must be either 'mysql' or 'postgres'."
  }
}

variable "db_engine_version" {
  type        = string
  description = "RDS database engine version"
  default     = "8.0"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# VPC and Networking
# ============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = {
    public_1 = {
      cidr              = "10.0.1.0/24"
      availability_zone = data.aws_availability_zones.available.names[0]
    }
    public_2 = {
      cidr              = "10.0.2.0/24"
      availability_zone = data.aws_availability_zones.available.names[1]
    }
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = each.key
  }
}

resource "aws_subnet" "private" {
  for_each = {
    private_1 = {
      cidr              = "10.0.10.0/24"
      availability_zone = data.aws_availability_zones.available.names[0]
    }
    private_2 = {
      cidr              = "10.0.11.0/24"
      availability_zone = data.aws_availability_zones.available.names[1]
    }
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.availability_zone

  tags = {
    Name = each.key
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["public_1"].id

  tags = {
    Name = "main-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ============================================================================
# Security Groups
# ============================================================================

resource "aws_security_group" "alb" {
  name_prefix = "alb-"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-sg"
  }
}

resource "aws_security_group" "asg" {
  name_prefix = "asg-"
  description = "Security group for ASG instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "asg-sg"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "rds-"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.db_engine == "mysql" ? 3306 : 5432
    to_port         = var.db_engine == "mysql" ? 3306 : 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.asg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-sg"
  }
}

# ============================================================================
# ALB
# ============================================================================

resource "aws_lb" "main" {
  name_prefix        = "alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  tags = {
    Name = "main-alb"
  }
}

resource "aws_lb_target_group" "main" {
  name_prefix = "tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = {
    Name = "main-tg"
  }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ============================================================================
# IAM for EC2
# ============================================================================

resource "aws_iam_role" "ec2_role" {
  name_prefix = "ec2-role-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "ec2-role"
  }
}

resource "aws_iam_role_policy" "ec2_cloudwatch" {
  name_prefix = "ec2-cloudwatch-"
  role        = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name_prefix = "ec2-profile-"
  role        = aws_iam_role.ec2_role.name
}

data "aws_caller_identity" "current" {}

# ============================================================================
# Launch Template and ASG
# ============================================================================

resource "aws_launch_template" "main" {
  name_prefix   = "lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2_profile.arn
  }

  network_interfaces {
    security_groups = [aws_security_group.asg.id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
              EOF
  )

  tags = {
    Name = "main-lt"
  }
}

resource "aws_autoscaling_group" "main" {
  name_prefix         = "asg-"
  vpc_zone_identifier = [for subnet in aws_subnet.private : subnet.id]
  target_group_arns   = [aws_lb_target_group.main.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  min_size         = 1
  max_size         = 3
  desired_capacity = 2

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
  }

  tag {
    key                 = "Name"
    value               = "asg-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# RDS
# ============================================================================

resource "aws_db_subnet_group" "main" {
  name_prefix = "db-subnet-"
  subnet_ids  = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "main-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier_prefix      = "db-"
  engine                 = var.db_engine
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  multi_az               = false
  publicly_accessible    = false
  skip_final_snapshot    = true
  
  backup_retention_period = 7

  tags = {
    Name = "main-db"
  }
}

output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDS database endpoint (hostname only)"
  value       = split(":", aws_db_instance.main.endpoint)[0]
}

output "rds_port" {
  description = "RDS database port"
  value       = aws_db_instance.main.port
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.main.name
}
