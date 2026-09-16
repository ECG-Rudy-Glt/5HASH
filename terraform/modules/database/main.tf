resource "random_password" "master" {
  length  = 24
  special = false # évite les caractères qui posent problème dans une URL de connexion PrestaShop
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.name}-db-subnet-group"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  db_name            = var.db_name
  username           = var.db_username
  password           = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.database_sg_id]

  multi_az            = var.multi_az
  skip_final_snapshot = true

  tags = {
    Name = "${var.name}-db"
  }
}

# Secret unique, partagé avec Ansible au déploiement (lookup amazon.aws.aws_secret) :
# évite de dupliquer le mot de passe RDS dans Ansible Vault.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.name}/rds/master"

  tags = {
    Name = "${var.name}-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
  })
}
