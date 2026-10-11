# ファイル名: providers.tf
```hcl
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
```

# ファイル名: variables.tf
```hcl
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
  description = "ASGで起動するEC2インスタンスタイプ"
  default     = "t3.micro"
}

variable "db_instance_class" {
  type        = string
  description = "RDSのインスタンスクラス"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "RDSに作成する初期データベース名"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "RDSのマスターユーザー名(パスワードはSecrets Managerで自動管理)"
  default     = "dbadmin"
}

variable "db_allocated_storage" {
  type        = number
  description = "RDSの割り当てストレージ容量(GiB)"
  default     = 20
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logsの保持日数"
  default     = 14
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
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

locals {
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

  common_tags = {
    Project = "haiku-benchmark"
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "haiku-benchmark-main" })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "haiku-benchmark-public-${each.key}" })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(local.common_tags, { Name = "haiku-benchmark-private-${each.key}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "haiku-benchmark-main" })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, { Name = "haiku-benchmark-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id

  tags = merge(local.common_tags, { Name = "haiku-benchmark-main" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "haiku-benchmark-public" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "haiku-benchmark-private" })
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

# -----------------------------------------------------------------------------
# Security Groups
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "haiku-benchmark-alb-"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "haiku-benchmark-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "haiku-benchmark-app-"
  description = "Security group for ASG instances"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "haiku-benchmark-app" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "haiku-benchmark-db-"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "haiku-benchmark-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to app instances"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound via NAT gateway"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_mysql_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from app instances"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/haiku-benchmark/app"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
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
      "${aws_cloudwatch_log_group.app.arn}:*",
    ]
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "haiku-benchmark-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name_prefix = "haiku-benchmark-cw-logs-"
  description = "Allow EC2 instances to write to the application log group"
  policy      = data.aws_iam_policy_document.cloudwatch_logs.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "haiku-benchmark-ec2-"
  role        = aws_iam_role.ec2.name

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ALB
# -----------------------------------------------------------------------------
resource "aws_lb" "app" {
  name_prefix        = "hb-"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = merge(local.common_tags, { Name = "haiku-benchmark-app" })
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

  tags = merge(local.common_tags, { Name = "haiku-benchmark-app" })

  lifecycle {
    create_before_destroy = true
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

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Launch Template / ASG
# -----------------------------------------------------------------------------
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
    echo "haiku-benchmark app" > /var/www/html/index.html
    systemctl enable --now httpd
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, { Name = "haiku-benchmark-app" })
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

  depends_on = [aws_nat_gateway.main]
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name_prefix = "haiku-benchmark-"
  subnet_ids  = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, { Name = "haiku-benchmark-main" })
}

resource "aws_db_instance" "main" {
  identifier_prefix = "haiku-benchmark-"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  port     = 3306

  # パスワードはAWS Secrets Managerで自動生成・管理する
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = merge(local.common_tags, { Name = "haiku-benchmark-main" })
}
```

# ファイル名: outputs.tf
```hcl
output "alb_dns_name" {
  description = "ALBのDNS名"
  value       = aws_lb.app.dns_name
}

output "rds_endpoint" {
  description = "RDSのエンドポイント(ホスト名のみ、認証情報は含まない)"
  value       = aws_db_instance.main.address
}
```