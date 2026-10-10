variable "region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  description = "S3バケット名(グローバルで一意である必要があります)"
  type        = string
  default     = "my-private-bucket-example-12345"
}
