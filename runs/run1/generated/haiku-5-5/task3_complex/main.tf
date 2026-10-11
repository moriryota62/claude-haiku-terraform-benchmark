locals {
  common_tags = {
    Project = "haiku-benchmark"
  }

  public_subnets = {
    for idx, cidr in var.public_subnet_cidrs : idx => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }

  private_subnets = {
    for idx, cidr in var.private_subnet_cidrs : idx => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
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
    values = ["al2023-ami-2023*-x86_64"]
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

# ---------------------------------------------------------------
# ネットワーク
# ---------------------------------------------------------------
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
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

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

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["0"].id

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
# セキュリティグループ
# ---------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "haiku-benchmark-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb-sg"
  })
}

resource "aws_security_group" "app" {
  name        = "haiku-benchmark-app-sg"
  description = "ASG instance security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (via NAT)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-app-sg"
  })
}

resource "aws_security_group" "db" {
  name        = "haiku-benchmark-db-sg"
  description = "RDS security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from app instances only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-sg"
  })
}

# ---------------------------------------------------------------
# ALB
# ---------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "haiku-benchmark-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-alb"
  })
}

resource "aws_lb_target_group" "app" {
  name        = "haiku-benchmark-tg"
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

# ---------------------------------------------------------------
# IAM (EC2用)
# ---------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/haiku-benchmark/*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/haiku-benchmark/*:*",
    ]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "haiku-benchmark-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2-role"
  })
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name   = "haiku-benchmark-cloudwatch-logs"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.cloudwatch_logs.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "haiku-benchmark-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-ec2-profile"
  })
}

# ---------------------------------------------------------------
# Launch Template / Auto Scaling Group
# ---------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "haiku-benchmark-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd
    systemctl enable --now httpd
    echo "OK from $(hostname)" > /var/www/html/index.html
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
    tags         = local.common_tags
  }

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-lt"
  })
}

resource "aws_autoscaling_group" "app" {
  name                      = "haiku-benchmark-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  tag {
    key                 = "Name"
    value               = "haiku-benchmark-app"
    propagate_at_launch = true
  }

  depends_on = [aws_route_table_association.private]
}

# ---------------------------------------------------------------
# RDS
# ---------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "haiku-benchmark-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db-subnet-group"
  })
}

resource "aws_db_instance" "main" {
  identifier        = "haiku-benchmark-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = var.rds_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  skip_final_snapshot        = true

  tags = merge(local.common_tags, {
    Name = "haiku-benchmark-db"
  })
}
