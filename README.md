# Taylor Shift's Ticket Shop : Infrastructure

Ce dépôt héberge le projet de fin de module 5HASH : la billetterie PrestaShop de Taylor Shift. L'infrastructure est provisionnée par **Terraform** et configurée par **Ansible**. Elle tourne sur **Floci**, un émulateur AWS local (`http://localhost.floci.io:4566`) comme vu en cours : aucun compte AWS n'est nécessaire. Floci a cependant des limites, détaillées dans [terraform/README.md §4](terraform/README.md#4-limites-dues-à-floci) et [ansible/README.md §6](ansible/README.md#6-limites-dues-à-floci).

> L'application n'est donc joignable que depuis la machine qui exécute Floci. Le code, lui, est portable tel quel vers un vrai compte AWS : seuls les endpoints du provider changent.

Documentation détaillée :

- [docs/architecture.md](docs/architecture.md) : schéma, fonctionnement et justification des choix ;
- [terraform/README.md](terraform/README.md) : modules, environnements, limites Floci ;
- [ansible/README.md](ansible/README.md) : inventaire dynamique, rôle, secrets.

## 1. Architecture

ALB public → Auto Scaling Group d'EC2 en subnets privés (PrestaShop en Docker, configuré par Ansible) → RDS MySQL managé.

Schéma, fonctionnement et justification de chaque choix : **[docs/architecture.md](docs/architecture.md)**.

> **Périmètre volontairement limité** : nous sommes restés proches de la consigne et avons choisi de ne pas complexifier l'architecture avec du cache (ElastiCache/Redis, CDN), de la supervision (Prometheus, Grafana) ou de la centralisation des logs. Ce seraient les premières évolutions pour une vraie mise en production (voir les limites au §2).

## 2. Trafic et scaling


- Les requêtes arrivent sur l'ALB, qui les répartit entre les instances saines du target group (health check HTTP `/` toutes les 15 s). Un cookie d'affinité de l'ALB (*sticky sessions*, 1 h) garde un client sur la même instance.
- L'ASG ajuste le nombre d'instances, entre `min_size` et `max_size`, avec deux politiques de *target tracking* : **600 requêtes par instance et par minute** (réagit dès l'arrivée du trafic, utile pour l'ouverture d'une vente) et **60 % de CPU moyen** (filet de sécurité). Il ajoute une instance dès qu'une politique le demande et n'en retire que si les deux sont d'accord.
- **Si une instance devient indisponible** :
  1. après 3 health checks en échec (environ 45 s), l'ALB cesse de lui envoyer du trafic et les autres instances absorbent la charge ;
  2. l'ASG (health check de type `ELB`) la termine et en lance une nouvelle ;
  3. les clients qui lui étaient rattachés sont redirigés vers une autre instance et perdent leur session.
- **Limites** :
  - une instance neuve n'est configurée qu'au prochain `terraform apply` suivi d'`ansible-playbook`, et met de toute façon plusieurs minutes à démarrer ;
  - pas de stockage partagé (EFS) ni de sessions partagées : l'affinité ALB atténue le problème sans le résoudre (répartition moins homogène, session perdue si l'instance tombe) ;
  - le seuil de 600 requêtes est une estimation, à calibrer par test de charge ;
  - RDS reste le goulot d'étranglement, faute de cache ;
  - une seule NAT Gateway.

## 3. Prérequis


| Outil | Version | Pourquoi |
|---|---|---|
| Docker + Compose | récent | Fait tourner Floci (et les « instances EC2 » qu'il émule) |
| Terraform | ≥ 1.10 | `use_lockfile` du backend S3 |
| AWS CLI | v2 | Crée le bucket du backend dans Floci |
| ansible-core | ≥ 2.15 et < 2.21 | `geerlingguy.docker` utilise `deb822_repository`. Le paquet `apt` de Debian 12 (2.14) est trop ancien. `cloud.terraform` 4.0.0 est incompatible avec 2.21 |
| boto3 / botocore | dans l'environnement d'Ansible | Lookup Secrets Manager, exécuté sur le poste |

**Floci ne s'installe pas** : c'est une image Docker, téléchargée par `docker compose up` (section 4).

**Debian / Ubuntu** :

```sh
# Docker (se reconnecter ensuite pour que le groupe docker soit pris en compte)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"

# Terraform (dépôt HashiCorp)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install

# Ansible (via pipx, pas apt) + boto3
sudo apt install -y pipx && pipx ensurepath
pipx install 'ansible-core>=2.15,<2.21'
pipx inject ansible-core boto3 botocore
```

**macOS** : installer Docker Desktop, puis :

```sh
brew tap hashicorp/tap && brew install hashicorp/tap/terraform awscli pipx
pipx install 'ansible-core>=2.15,<2.21' && pipx inject ansible-core boto3 botocore
```

Vérifier : `docker compose version`, `terraform version`, `aws --version`, `ansible --version`.

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

**Clés et identifiants : rien n'est fourni, rien n'est à demander.**

- **Clé SSH** (étape 2) : chacun génère la sienne, et elle n'est jamais versionnée (`.keys/` est gitignoré).
  - La **publique** est lue par Terraform et injectée dans les instances.
  - La **privée** reste sur le poste. Ansible n'en reçoit que le chemin, via l'inventaire.
  - Si la clé est régénérée après un `apply`, les instances existantes gardent l'ancienne : relancer `terraform apply`, puis remplacer les instances (voir section 8).
- **Identifiants AWS** : `test`/`test` sont des valeurs factices que Floci ne vérifie jamais. Il n'y a ni compte ni clé AWS à créer.

**4. Mot de passe Ansible Vault.** Les identifiants admin de PrestaShop sont chiffrés dans [ansible/group_vars/all/vault.yml](ansible/group_vars/all/vault.yml).

> ⚠️ **Le mot de passe Vault est versionné volontairement** dans [.vault-pass](.vault-pass), à la racine du dépôt. Nous l'avons fait **exprès, pour que vous puissiez lancer le playbook** sans nous le demander. Dans un vrai projet, ce fichier serait gitignoré et le mot de passe transmis hors du dépôt (gestionnaire de mots de passe, variable de CI).

- **Avec `--ask-vault-pass`** (séquence de test) : à l'invite `Vault password:`, saisir le contenu de `.vault-pass` (`cat .vault-pass`).
- **Sans le retaper** : remplacer `--ask-vault-pass` par `--vault-password-file .vault-pass`.
- **Avec son propre mot de passe** : recréer le fichier Vault. `ansible-vault` demande un nouveau mot de passe puis ouvre un éditeur :

  ```sh
  rm ansible/group_vars/all/vault.yml
  ansible-vault create ansible/group_vars/all/vault.yml
  ```

  Contenu à saisir (le mot de passe admin doit faire au moins 8 caractères) :

  ```yaml
  vault_ps_admin_mail: admin@example.com
  vault_ps_admin_passwd: ChangeMe-2026
  ```

## 5. Déploiement

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply
ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # changed=0 attendu
```

Sans `-var-file`, Terraform applique les valeurs par défaut, identiques à `dev` (1 instance). Les autres environnements sont décrits à la section 6.

> Si `ANSIBLE_CONFIG` est défini dans ton shell, lancer `unset ANSIBLE_CONFIG` avant : il remplace le `ansible.cfg` du dépôt.
>
> **macOS** : préfixer les commandes `ansible-*` par `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`, sinon le worker plante sur le lookup Secrets Manager.

**Endpoint** : lancer `terraform -chdir=terraform output alb_dns_name`, puis ouvrir `http://<valeur>/` (par exemple `http://ticket-shop-dev-alb-xxxx.elb.localhost.floci.io/`).

Le premier playbook dure environ 15 minutes : il installe Docker, puis attend que PrestaShop ait fini de s'installer dans RDS. C'est long surtout à cause du driver de stockage Docker **`vfs`**. Les « EC2 » de Floci sont elles-mêmes des conteneurs, et `overlay2` échoue en Docker-in-Docker. `vfs` fonctionne, mais il copie chaque couche de l'image en entier au lieu de les superposer, ce qui rend le démarrage du conteneur PrestaShop très lent. Sur un vrai EC2, avec `overlay2`, cette étape ne prend que quelques minutes (voir [ansible/README.md §6](ansible/README.md#6-limites-dues-à-floci)). À la fin, le playbook affiche les deux URL :

- **boutique** : `http://<alb_dns_name>/` ;
- **back-office** : `http://<alb_dns_name>/admin-ticketshop/`, avec les identifiants du Vault.

> **Accès depuis un autre poste (Remote SSH, VPN) comme mon cas personnel (rudy)** : les noms `*.localhost.floci.io` pointent vers `127.0.0.1`. Depuis un autre poste que celui qui fait tourner Floci, le navigateur appelle donc sa propre machine (`ERR_CONNECTION_REFUSED`). Le port local doit rester **80**, car PrestaShop redirige vers son domaine, sans numéro de port.
>
> - **Remote SSH (VS Code)** : onglet **Ports**, transférer le port `80` et vérifier que l'adresse locale est `localhost:80`. Sinon, clic droit → _Change Local Address Port_ → `80`.
> - **SSH en ligne de commande** : lancer, **sur son poste**, `sudo ssh -i ~/.ssh/<clé> -L 80:localhost:80 <user>@<ip-machine-floci>`. Le `sudo` est nécessaire pour ouvrir le port 80 en local sous Linux et macOS.
> - **VPN / même réseau** : Floci publie le port 80 sur toutes les interfaces. Il suffit d'ajouter au fichier hosts du poste (`/etc/hosts`, ou `C:\Windows\System32\drivers\etc\hosts`) la ligne `<ip-machine-floci> <alb_dns_name>`, puis d'ouvrir `http://<alb_dns_name>/`.

Pour vérifier la connexion à la base : la vitrine affiche le catalogue de démonstration, que PrestaShop a écrit dans RDS au premier démarrage (`PS_INSTALL_AUTO`).

## 6. Environnements (dev / staging / prod)

Chaque environnement a son **workspace** Terraform (state isolé) et son **fichier de variables**. Toutes les ressources sont nommées `ticket-shop-<env>-*`. Terraform refuse d'appliquer si le workspace ne correspond pas à `environment` (`default` ↔ dev).

```sh
terraform -chdir=terraform workspace new staging   # une seule fois
terraform -chdir=terraform workspace select staging
terraform -chdir=terraform apply -var-file=envs/staging.tfvars
```

| Env     | Workspace | Instance | ASG min/max/desired | RDS Multi-AZ |
| ------- | --------- | -------- | ------------------- | ------------ |
| dev     | `default` | t3.micro | 1 / 2 / 1           | non          |
| staging | `staging` | t3.micro | 2 / 3 / 2           | non          |
| prod    | `prod`    | t3.small | 2 / 6 / 2           | oui          |

## 7. Secrets

Le dépôt ne contient aucun secret en clair, sauf le mot de passe Vault (`.vault-pass`), versionné exprès pour l'évaluation (voir §4).

| Secret                        | Généré par                    | Stocké dans                                                                          | Lu par Ansible via                                   |
| ----------------------------- | ----------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| Mot de passe RDS              | Terraform (`random_password`) | Secrets Manager                                                                      | lookup`amazon.aws.secretsmanager_secret`             |
| Identifiants admin PrestaShop | l'équipe                      | Ansible Vault ([ansible/group_vars/all/vault.yml](ansible/group_vars/all/vault.yml)) | `--ask-vault-pass` (mot de passe dans `.vault-pass`) |
| Clé SSH                       | `ssh-keygen`                  | `.keys/` (gitignoré)                                                                 | chemin transmis par l'inventaire, jamais le contenu  |

## 8. Exploitation et maintenance

- **Mettre à jour l'application** : modifier `prestashop_image` ou les templates du rôle `prestashop`, puis relancer `ansible-playbook`. Le handler ne redéploie le conteneur que si sa configuration a changé.
- **Changer la capacité** : modifier `min_size`, `max_size` ou `desired_capacity` dans `envs/<env>.tfvars`, lancer `terraform apply`, puis `ansible-playbook` pour configurer les nouvelles instances.
- **Remplacer une instance** (y compris après un changement d'AMI ou de type) : lancer un _instance refresh_ sur l'ASG, puis `terraform apply` et `ansible-playbook`.
- **Faire tourner le mot de passe RDS** : `terraform -chdir=terraform apply -replace=module.database.random_password.master`, puis `ansible-playbook`, qui relit le secret et redéploie.
- **Consulter les logs** : `docker logs prestashop-prestashop-1` sur l'instance. Ils ne sont pas encore centralisés.

### Tout supprimer et redéployer de zéro

```sh
unset ANSIBLE_CONFIG                                   # si défini : il remplacerait le ansible.cfg du dépôt
terraform -chdir=terraform workspace select default
terraform -chdir=terraform destroy
terraform -chdir=terraform workspace delete staging    # seulement s'il existe et que son state est vide
terraform -chdir=terraform apply
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # changed=0 attendu
```

Pour supprimer staging ou prod, sélectionner d'abord le workspace correspondant et ajouter `-var-file=envs/<env>.tfvars` au `destroy`.

## 9. Structure du dépôt

```
compose.yml            Floci
ansible.cfg            à la racine, pour être détecté par la séquence de test (voir ansible/README.md)
terraform/             modules network, security, compute, database ; ansible.tf ; envs/*.tfvars
ansible/               inventory.yml, requirements.yml, site.yml, group_vars/, roles/prestashop/
docs/architecture.md   schéma et justification des choix
```

Projet réalisé par MAZZON Paul, BOULAND Hugo et GAULT Rudy, module 5HASH, Supinfo.
