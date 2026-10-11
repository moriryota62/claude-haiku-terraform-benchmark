# ファイル名: providers.tf

```hcl
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
```

# ファイル名: variables.tf

```hcl
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

variable "db_master_username" {
  type        = string
  description = "Master username for RDS"
  default     = "admin"
}

variable "db_master_password" {
  type        = string
  description = "Master password for RDS"
  sensitive   = true
}

variable "db_name" {
  type        = string
  description = "Database name"
  default     = "haikusdb"
}
```

# ファイル名: main.tf

```hcl
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

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "haiku-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "haiku-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  for_each = {
    public_1a = {
      cidr_block            = "10.0.1.0/24"
      availability_zone_idx = 0
    }
    public_1c = {
      cidr_block            = "10.0.2.0/24"
      availability_zone_idx = 1
    }
  }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr_block
  availability_zone       = data.aws_availability_zones.available.names[each.value.availability_zone_idx]
  map_public_ip_on_launch = true

  tags = {
    Name = "haiku-${each.key}"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  for_each = {
    private_1a = {
      cidr_block            = "10.0.10.0/24"
      availability_zone_idx = 0
    }
    private_1c = {
      cidr_block            = "10.0.11.0/24"
      availability_zone_idx = 1
    }
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr_block
  availability_zone = data.aws_availability_zones.available.names[each.value.availability_zone_idx]

  tags = {
    Name = "haiku-${each.key}"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "haiku-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateway
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["public_1a"].id

  tags = {
    Name = "haiku-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = {
    Name = "haiku-public-rt"
  }
}

# Public Route Table Association
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "haiku-private-rt"
  }
}

# Private Route Table Association
resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "haiku-alb-sg"
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
    Name = "haiku-alb-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "haiku-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  tags = {
    Name = "haiku-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "main" {
  name        = "haiku-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = {
    Name = "haiku-tg"
  }
}

# ALB Listener
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ASG Security Group
resource "aws_security_group" "asg" {
  name        = "haiku-asg-sg"
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
    Name = "haiku-asg-sg"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "haiku-ec2-role"

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
    Name = "haiku-ec2-role"
  }
}

# IAM Policy for CloudWatch Logs
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "haiku-cloudwatch-logs-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/haiku/*"
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "haiku-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Launch Template
resource "aws_launch_template" "main" {
  name_prefix   = "haiku-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2_profile.arn
  }

  network_interfaces {
    security_groups             = [aws_security_group.asg.id]
    delete_on_termination       = true
    associate_public_ip_address = false
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

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "haiku-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "haiku-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "main" {
  name                = "haiku-asg"
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

  tag {
    key                 = "Name"
    value               = "haiku-asg-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name        = "haiku-rds-sg"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
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
    Name = "haiku-rds-sg"
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "haiku-db-subnet-group"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "haiku-db-subnet-group"
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier            = "haiku-db"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = var.db_instance_class
  allocated_storage    = 20
  storage_type         = "gp2"
  db_name              = var.db_name
  username             = var.db_master_username
  password             = var.db_master_password
  db_subnet_group_name = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  
  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  tags = {
    Name = "haiku-db"
  }
}
```

# ファイル名: outputs.tf

```hcl
output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDS instance endpoint (address only)"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDS instance port"
  value       = aws_db_instance.main.port
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [for subnet in aws_subnet.private : subnet.id]
}
```