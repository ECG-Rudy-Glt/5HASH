output "endpoint" {
  description = "Adresse de l'instance RDS"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port de l'instance RDS"
  value       = aws_db_instance.this.port
}

output "secret_arn" {
  description = "ARN du secret Secrets Manager contenant les identifiants RDS (à lire depuis Ansible)"
  value       = aws_secretsmanager_secret.db.arn
}
