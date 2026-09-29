variable "name" {
  description = "Préfixe de nommage des ressources compute"
  type        = string
}

variable "vpc_id" {
  description = "VPC du target group"
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets publics pour l'ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets privés pour les instances applicatives"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group de l'ALB"
  type        = string
}

variable "app_sg_id" {
  description = "Security group des instances applicatives"
  type        = string
}

variable "ami_id" {
  description = "AMI de base pour les instances EC2 (Ansible installe Docker + déploie PrestaShop ensuite)"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée sur les instances (utilisée par Ansible) — jamais la clé privée"
  type        = string
}

variable "min_size" {
  description = "Nombre minimum d'instances dans l'ASG"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Nombre maximum d'instances dans l'ASG"
  type        = number
  default     = 4
}

variable "desired_capacity" {
  description = "Nombre d'instances souhaité dans l'ASG"
  type        = number
  default     = 2
}

variable "cpu_target_value" {
  description = "Cible de la politique de scaling target-tracking (% CPU moyen)"
  type        = number
  default     = 60
}

variable "request_count_target_value" {
  description = "Cible de la politique de scaling target-tracking (requêtes par instance et par minute sur l'ALB)"
  type        = number
  default     = 600
}

variable "stickiness_duration" {
  description = "Durée (s) du cookie d'affinité de l'ALB : un client reste sur la même instance, dont le volume local porte sa session et son panier"
  type        = number
  default     = 3600
}

variable "health_check_grace_period" {
  description = "Délai (s) avant que l'ASG tienne compte du health check ALB : couvre l'attente puis l'exécution d'Ansible (installation Docker + PrestaShop)"
  type        = number
  default     = 1800
}
