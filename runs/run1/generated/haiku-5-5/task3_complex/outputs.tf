output "alb_dns_name" {
  description = "Application Load BalancerのDNS名"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDSインスタンスのエンドポイントホスト名(パスワード等の機密情報は含まない)"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  description = "RDSインスタンスのポート番号"
  value       = aws_db_instance.main.port
}
