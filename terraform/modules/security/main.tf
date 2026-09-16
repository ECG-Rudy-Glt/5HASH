# NOTE : Floci accepte et restitue ces security groups (describe/ingress rules)
# mais ne les applique pas comme un vrai firewall (pas de filtrage réel du trafic
# conteneur-à-conteneur). Elles sont néanmoins déclarées correctement ici pour
# que le code soit portable tel quel vers un compte AWS réel.

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "ALB public - HTTP/HTTPS depuis Internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Instances PrestaShop - HTTP depuis l'ALB uniquement"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP depuis ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-db-"
  description = "RDS - MySQL depuis les instances applicatives uniquement"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL depuis les instances app"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}
