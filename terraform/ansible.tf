# Inventaire décrit par Terraform : les instances de l'ASG ne sont pas
# énumérables via for_each direct, donc découvertes par data source filtrée
# par tag. ansible_host/ansible_group ne créent rien, ils n'existent que
# dans le state — cloud.terraform.terraform_provider les lit côté Ansible.

data "aws_instances" "app" {
  filter {
    name   = "tag:Name"
    values = ["${local.name}-app"]
  }

  instance_state_names = ["running"]

  depends_on = [module.compute]
}

# Les clés du for_each doivent être connues au plan, pas les ids de l'ASG
# (connus à l'apply) : on indexe sur 0..desired_capacity-1 et on ne laisse
# que la valeur dépendre de l'apply, via element().
resource "ansible_host" "app" {
  for_each = { for idx in range(var.desired_capacity) : tostring(idx) => idx }

  name   = "app-${each.key}"
  groups = ["prestashop"]

  variables = {
    floci_instance = element(data.aws_instances.app.ids, each.value)
    ansible_user   = "root"

    # IP précise, pas 0.0.0.0 : conflit sinon avec le socat de métadonnées
    # interne de Floci (169.254.169.254:80).
    private_ip = element(data.aws_instances.app.private_ips, each.value)

    # Chemin, jamais le contenu : file(...) déposerait la clé privée en clair
    # dans le state.
    ansible_ssh_private_key_file = ".keys/ticket_shop"
  }
}

resource "ansible_group" "prestashop" {
  name = "prestashop"

  variables = {
    # "environment" est un nom réservé par Ansible, d'où app_environment.
    app_environment = var.environment

    db_secret_arn = module.database.secret_arn
    db_endpoint   = module.database.endpoint
    db_port       = module.database.port

    alb_dns_name = module.compute.alb_dns_name
  }
}
