# L'inventaire, décrit par Terraform (pattern J4-07, adapté à un Auto Scaling
# Group : contrairement à des aws_instance fixes, les instances de l'ASG ne
# sont pas énumérables par un for_each direct sur une ressource qu'on déclare
# — on les découvre via une data source filtrée par tag, réévaluée à chaque
# plan/apply.
#
# Ces ressources ansible_host / ansible_group ne créent rien : elles
# n'existent que dans le state. Le greffon cloud.terraform.terraform_provider
# les y lit, et en fabrique l'inventaire d'Ansible.

data "aws_instances" "app" {
  filter {
    name   = "tag:Name"
    values = ["${local.name}-app"]
  }

  instance_state_names = ["running"]

  depends_on = [module.compute]
}


# Terraform doit connaître l'ensemble des clés d'un for_each AU PLAN, alors
# que data.aws_instances.app.ids ne sera connu qu'à l'apply (il dépend
# d'instances créées dans ce même apply) — "Invalid for_each argument" sinon.
# On indexe donc sur des clés statiques (0..desired_capacity-1, connues sans
# apply) et on ne laisse que la VALEUR (l'id réel) dépendre de l'apply, via
# element() qui ne échoue jamais même si la liste est momentanément plus
# courte (ex. ASG encore en train de démarrer une instance).
resource "ansible_host" "app" {
  for_each = { for idx in range(var.desired_capacity) : tostring(idx) => idx }

  name   = "app-${each.key}"
  groups = ["prestashop"]

  variables = {
    # L'identifiant de l'instance, jamais une adresse saisie à la main :
    # Ansible s'en sert pour retrouver le port SSH publié par Floci (voir
    # ansible/group_vars/prestashop.yml).
    floci_instance = element(data.aws_instances.app.ids, each.value)
    ansible_user   = "root"

    # L'adresse privée réelle de l'instance (pas 0.0.0.0) : sur Floci, publier
    # le port 80 de PrestaShop en écoute large (0.0.0.0) entre en conflit avec
    # le socat de métadonnées interne de Floci (169.254.169.254:80). Se lier à
    # l'IP précise évite le conflit — et c'est de toute façon cette IP que
    # l'ALB utilise pour joindre l'instance.
    private_ip = element(data.aws_instances.app.private_ips, each.value)

    # Un CHEMIN, jamais le contenu : écrire file(...) déposerait la clé
    # privée en clair dans le state. Relatif à la racine du dépôt, d'où sont
    # lancées les commandes ansible (voir ansible.cfg à la racine).
    ansible_ssh_private_key_file = ".keys/ticket_shop"
  }
}

resource "ansible_group" "prestashop" {
  name = "prestashop"

  variables = {
    # "environment" est un nom réservé par Ansible (injection de variables
    # d'environnement dans une tâche) : on l'évite pour ne pas le masquer.
    app_environment = var.environment

    # Ce que Terraform sait et qu'Ansible ignore : où lire le secret RDS.
    # Jamais la valeur — seulement l'ARN, lu à la volée par un lookup Ansible.
    db_secret_arn = module.database.secret_arn
    db_endpoint   = module.database.endpoint
    db_port       = module.database.port

    alb_dns_name = module.compute.alb_dns_name
  }
}
