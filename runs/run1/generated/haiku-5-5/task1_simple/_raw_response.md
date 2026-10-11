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
}

variable "region" {
  type        = string
  description = "AWSリソースを作成するリージョン"
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  type        = string
  description = "作成するS3バケット名(グローバルで一意である必要があります)"
  default     = "my-private-s3-bucket-example-20240101"
}

resource "aws_s3_bucket" "main" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  description = "作成したS3バケット名"
  value       = aws_s3_bucket.main.bucket
}

output "bucket_arn" {
  description = "作成したS3バケットのARN"
  value       = aws_s3_bucket.main.arn
}
```