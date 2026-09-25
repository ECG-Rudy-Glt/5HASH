output "alb_dns_name" {
  description = "Nom DNS public de l'ALB"
  value       = aws_lb.app.dns_name
}

output "asg_name" {
  description = "Nom de l'Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  description = "ARN du target group"
  value       = aws_lb_target_group.app.arn
}
