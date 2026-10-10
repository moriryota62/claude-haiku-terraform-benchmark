variable "region" {
  type        = string
  description = "AWSリソースを作成するリージョン"
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  type        = string
  description = "作成するS3バケット名(グローバルで一意である必要があります)"
  default     = "example-private-bucket-change-me"
}
