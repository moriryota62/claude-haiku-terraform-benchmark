output "bucket_name" {
  type        = string
  description = "作成したS3バケットの名前"
  value       = aws_s3_bucket.main.id
}

output "bucket_arn" {
  type        = string
  description = "作成したS3バケットのARN"
  value       = aws_s3_bucket.main.arn
}
