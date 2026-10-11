# ファイル名: providers.tf

```hcl
terraform {
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

variable "s3_bucket_name" {
  type        = string
  description = "Name of the S3 bucket"
  default     = "my-private-bucket"
}
```

# ファイル名: main.tf

```hcl
resource "aws_s3_bucket" "private" {
  bucket = var.s3_bucket_name
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
output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.private.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.private.arn
}
```