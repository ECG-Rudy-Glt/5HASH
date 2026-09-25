output "alb_dns_name" {
  description = "Endpoint HTTP de l'application (à mettre derrière un enregistrement DNS en prod)"
  value       = module.compute.alb_dns_name
}

output "asg_name" {
  description = "Nom de l'Auto Scaling Group"
  value       = module.compute.asg_name
}

output "vpc_id" {
  description = "ID du VPC"
  value       = module.network.vpc_id
}

output "db_endpoint" {
  description = "Adresse de l'instance RDS"
  value       = module.database.endpoint
}

output "db_secret_arn" {
  description = "ARN du secret Secrets Manager contenant les identifiants RDS"
  value       = module.database.secret_arn
}
