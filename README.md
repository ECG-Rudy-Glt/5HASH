# Taylor Shift's Ticket Shop — Infrastructure

Ce dépôt héberge PrestaShop, la billetterie de concerts de Taylor Shift. L'infrastructure est provisionnée par **Terraform** et configurée par **Ansible**. Elle tourne sur **Floci**, un émulateur AWS local (`http://localhost.floci.io:4566`) : aucun compte AWS n'est nécessaire.

> L'application n'est donc joignable que depuis la machine qui exécute Floci. Le code, lui, est portable tel quel vers un vrai compte AWS : seuls les endpoints du provider changent.

Documentation détaillée :
- [docs/architecture.md](docs/architecture.md) : schéma, choix, limites, plan multi-région ;
- [docs/guide-technique.md](docs/guide-technique.md) : fonctionnement détaillé du code, outils utilisés, correspondance avec le barème ;
- [terraform/README.md](terraform/README.md) : modules, environnements, limites Floci ;
- [ansible/README.md](ansible/README.md) : inventaire dynamique, rôle, secrets.

## 1. Architecture

```
Internet ─► ALB (subnets publics, SG : 80 depuis 0.0.0.0/0)
              │ target group, health check /
              ▼
            Auto Scaling Group EC2 (subnets privés, SG : 80 depuis l'ALB)
            PrestaShop en Docker, installé par Ansible
              │ 3306
              ▼
            RDS MySQL managé (subnets privés, SG : 3306 depuis les instances)
```

- **Réseau** : 1 VPC sur 2 AZ, subnets publics (ALB, NAT) et privés (EC2, RDS).
- **Application sur EC2** : le sujet impose au moins une instance EC2 configurée par Ansible. L'ASG la rend scalable.
- **Base sur RDS** : les sauvegardes et le failover (Multi-AZ en `prod`) sont gérés par AWS, pas réinventés dans Ansible. La base reste hors du scaling applicatif.
- **Secret RDS** : généré par Terraform, stocké dans Secrets Manager, lu par Ansible. Il n'est jamais dupliqué.
- **State Terraform** : backend S3 avec verrouillage natif.

## 2. Trafic et scaling

- Les requêtes arrivent sur l'ALB, qui les répartit entre les instances saines du target group (health check HTTP `/` toutes les 15 s).
- L'ASG ajuste le nombre d'instances avec une politique de *target tracking* à 60 % de CPU moyen, entre `min_size` et `max_size`.
- **Si une instance devient indisponible** :
  1. après 3 health checks en échec (environ 45 s), l'ALB cesse de lui envoyer du trafic et les autres instances absorbent la charge ;
  2. l'ASG (health check de type `ELB`) la termine et en lance une nouvelle.
- **Limites** :
  - une instance neuve n'est configurée qu'au prochain `terraform apply` suivi d'`ansible-playbook` ;
  - pas de stockage partagé (EFS) ni de sessions partagées ;
  - RDS reste le goulot d'étranglement, faute de cache ;
  - une seule NAT Gateway.

  Le détail et les pistes d'amélioration sont dans [docs/architecture.md §4](docs/architecture.md#4-limites-connues).

## 3. Prérequis

- Docker (avec Compose), Terraform ≥ 1.10, AWS CLI.
- **ansible-core ≥ 2.15** : le rôle `geerlingguy.docker` utilise `deb822_repository`. Le paquet `apt` de Debian 12 est trop ancien (2.14), il faut installer via pipx :
  ```sh
  pipx install ansible-core
  pipx inject ansible-core boto3 botocore   # utilisés par le lookup Secrets Manager, exécuté sur le poste
  ```
- Le mot de passe Ansible Vault, fourni par l'équipe.

## 4. Mise en place, à faire une fois avant la séquence de test

```sh
# 1. Démarrer Floci (publie aussi le port 80, écouté par l'ALB)
docker compose up -d

# 2. Générer la clé SSH d'Ansible. Terraform lit .keys/ticket_shop.pub par défaut.
mkdir -p .keys && ssh-keygen -t ed25519 -f .keys/ticket_shop -N ""

# 3. Créer le bucket du backend Terraform (le verrouillage use_lockfile ne demande pas de DynamoDB)
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test   # identifiants factices de Floci
aws --endpoint-url=http://localhost.floci.io:4566 --region us-east-1 \
  s3api create-bucket --bucket ticket-shop-tfstate
aws --endpoint-url=http://localhost.floci.io:4566 --region us-east-1 \
  s3api put-bucket-versioning --bucket ticket-shop-tfstate --versioning-configuration Status=Enabled
```

Le backend est déclaré dans [terraform/backend.tf](terraform/backend.tf).

> Floci ne conserve rien quand son conteneur est recréé, ni les ressources ni le bucket de state. Après un redémarrage, reprendre à l'étape 3.

## 5. Déploiement

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply
ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # changed=0 attendu
```

Sans `-var-file`, Terraform applique les valeurs par défaut, identiques à `dev` (1 instance). Les autres environnements sont décrits au §6.

> Si `ANSIBLE_CONFIG` est défini dans ton shell, lancer `unset ANSIBLE_CONFIG` avant : il remplace le `ansible.cfg` du dépôt.
>
> **macOS** : préfixer les commandes `ansible-*` par `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`, sinon le worker plante sur le lookup Secrets Manager.

**Endpoint** : lancer `terraform -chdir=terraform output alb_dns_name`, puis ouvrir `http://<valeur>/` (par exemple `http://ticket-shop-dev-alb-xxxx.elb.localhost.floci.io/`).

Le premier playbook dure environ 15 minutes : il installe Docker, puis attend que PrestaShop ait fini de s'installer dans RDS. À la fin, il affiche les deux URL :
- **boutique** : `http://<alb_dns_name>/` ;
- **back-office** : `http://<alb_dns_name>/admin-ticketshop/`, avec les identifiants du Vault.

Pour vérifier la connexion à la base : la vitrine affiche le catalogue de démonstration, que PrestaShop a écrit dans RDS au premier démarrage (`PS_INSTALL_AUTO`).

## 6. Environnements (dev / staging / prod)

Chaque environnement a son **workspace** Terraform (state isolé) et son **fichier de variables**. Toutes les ressources sont nommées `ticket-shop-<env>-*`. Terraform refuse d'appliquer si le workspace ne correspond pas à `environment` (`default` ↔ dev).

```sh
terraform -chdir=terraform workspace new staging   # une seule fois
terraform -chdir=terraform workspace select staging
terraform -chdir=terraform apply -var-file=envs/staging.tfvars
```

| Env | Workspace | Instance | ASG min/max/desired | RDS Multi-AZ |
|---|---|---|---|---|
| dev | `default` | t3.micro | 1 / 2 / 1 | non |
| staging | `staging` | t3.micro | 2 / 3 / 2 | non |
| prod | `prod` | t3.small | 2 / 6 / 2 | oui |

## 7. Secrets

Le dépôt ne contient aucun secret en clair.

| Secret | Généré par | Stocké dans | Lu par Ansible via |
|---|---|---|---|
| Mot de passe RDS | Terraform (`random_password`) | Secrets Manager | lookup `amazon.aws.secretsmanager_secret` |
| Identifiants admin PrestaShop | l'équipe | Ansible Vault ([ansible/group_vars/all/vault.yml](ansible/group_vars/all/vault.yml)) | `--ask-vault-pass` |
| Clé SSH | `ssh-keygen` | `.keys/` (gitignoré) | chemin transmis par l'inventaire, jamais le contenu |

## 8. Exploitation et maintenance

- **Mettre à jour l'application** : modifier `prestashop_image` ou les templates du rôle `prestashop`, puis relancer `ansible-playbook`. Le handler ne redéploie le conteneur que si sa configuration a changé.
- **Changer la capacité** : modifier `min_size`, `max_size` ou `desired_capacity` dans `envs/<env>.tfvars`, lancer `terraform apply`, puis `ansible-playbook` pour configurer les nouvelles instances.
- **Remplacer une instance** (y compris après un changement d'AMI ou de type) : lancer un *instance refresh* sur l'ASG, puis `terraform apply` et `ansible-playbook`.
- **Faire tourner le mot de passe RDS** : `terraform -chdir=terraform apply -replace=module.database.random_password.master`, puis `ansible-playbook`, qui relit le secret et redéploie.
- **Consulter les logs** : `docker logs prestashop-prestashop-1` sur l'instance. Ils ne sont pas encore centralisés.
- **Tout supprimer** : `terraform -chdir=terraform destroy`.

## 9. Structure du dépôt

```
compose.yml            Floci
ansible.cfg            à la racine, pour être détecté par la séquence de test (voir ansible/README.md)
terraform/             modules network, security, compute, database ; ansible.tf ; envs/*.tfvars
ansible/               inventory.yml, requirements.yml, site.yml, group_vars/, roles/prestashop/
docs/architecture.md   schéma détaillé, limites, plan multi-région
docs/guide-technique.md  fonctionnement détaillé du code
```

Projet de groupe (3 personnes), module 5HASH, Supinfo.
