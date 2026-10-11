variable "region" {
  type        = string
  description = "AWSプロバイダで使用するリージョン"
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  type        = string
  description = "作成するS3バケットの名前(グローバルで一意である必要があります)"
  default     = "example-private-bucket-20240101-change-me"
}
