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

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "パブリックサブネットのCIDRリスト(2つ指定し、それぞれ別AZに配置)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "public_subnet_cidrs は2つ指定してください。"
  }
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "プライベートサブネットのCIDRリスト(2つ指定し、それぞれ別AZに配置)"
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs は2つ指定してください。"
  }
}

variable "instance_type" {
  type        = string
  description = "Auto Scaling Groupで起動するEC2のインスタンスタイプ"
  default     = "t3.micro"
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

variable "asg_desired_capacity" {
  type        = number
  description = "Auto Scaling Groupの希望インスタンス数"
  default     = 2
}

variable "rds_instance_class" {
  type        = string
  description = "RDSのインスタンスクラス"
  default     = "db.t3.micro"
}

variable "db_name" {
  type        = string
  description = "作成するデータベース名"
  default     = "appdb"
}

variable "db_username" {
  type        = string
  description = "RDSマスターユーザー名"
  default     = "dbadmin"
}

variable "db_password" {
  type        = string
  description = "RDSマスターユーザーのパスワード(tfvarsや環境変数TF_VAR_db_passwordで指定)"
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8
    error_message = "db_password は8文字以上で指定してください。"
  }
}
