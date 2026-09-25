output "alb_sg_id" {
  description = "Security group de l'ALB"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "Security group des instances applicatives"
  value       = aws_security_group.app.id
}

output "database_sg_id" {
  description = "Security group de RDS"
  value       = aws_security_group.database.id
}
