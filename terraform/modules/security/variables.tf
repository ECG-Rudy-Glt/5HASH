variable "name" {
  description = "Préfixe de nommage des security groups"
  type        = string
}

variable "vpc_id" {
  description = "VPC dans lequel créer les security groups"
  type        = string
}
