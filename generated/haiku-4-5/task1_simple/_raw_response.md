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
}
```

# ファイル名: variables.tf

```hcl
variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  type        = string
  description = "S3 bucket name"
  default     = "my-private-bucket"
}
```

# ファイル名: main.tf

```hcl
resource "aws_s3_bucket" "private" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "private" {
  bucket = aws_s3_bucket.private.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  bucket = aws_s3_bucket.private.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "private" {
  bucket = aws_s3_bucket.private.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

# ファイル名: outputs.tf

```hcl
output "bucket_name" {
  value       = aws_s3_bucket.private.id
  description = "The name of the S3 bucket"
}

output "bucket_arn" {
  value       = aws_s3_bucket.private.arn
  description = "The ARN of the S3 bucket"
}
```