# Guide technique — Taylor Shift's Ticket Shop

Ce guide explique comment fonctionne tout le dépôt : l'architecture, le rôle de chaque fichier, les providers, modules, collections et rôles utilisés, et la façon dont l'ensemble répond au sujet. Il sert à comprendre le projet en profondeur et à préparer la soutenance. Pour simplement déployer, le [README](../README.md) suffit.

---

## 1. Le projet en une page

**Le besoin** : héberger PrestaShop (image Docker Hub) pour une billetterie qui doit encaisser un pic de trafic à l'ouverture des ventes.

**La réponse** :

| Brique | Outil | Rôle |
|---|---|---|
| Émulation AWS | **Floci** (conteneur Docker, port 4566) | Fait tourner EC2, ELB, ASG, RDS, Secrets Manager et S3 en local, sans compte AWS |
| Infrastructure | **Terraform** | Crée le réseau, les pare-feu, le load balancer, les instances, la base, le secret, *et* l'inventaire Ansible |
| Configuration | **Ansible** | Installe Docker sur les instances, lit le secret de la base et lance le conteneur PrestaShop |

**Le fil conducteur** : Terraform décrit l'infrastructure, puis Ansible la configure à partir de ce que Terraform lui transmet. Rien n'est recopié à la main : ni IP, ni mot de passe, ni liste de serveurs.

```
docker compose up -d        → Floci démarre (faux AWS local)
terraform init              → télécharge les providers, se connecte au state S3
terraform apply             → crée VPC, SG, ALB, ASG + EC2, RDS, secret, inventaire
ansible-galaxy install      → télécharge les collections et le rôle Docker
ansible-inventory --graph   → affiche les hôtes lus dans le state Terraform
ansible-playbook (1er)      → installe Docker et PrestaShop sur chaque EC2
ansible-playbook (2e)       → ne change rien : c'est l'idempotence
navigateur → ALB            → la boutique, dont les données sont dans RDS
```

---

## 2. Architecture

```
                    Internet (ici : le poste qui exécute Floci)
                                   │ HTTP 80
                     ┌─────────────▼──────────────┐
  Subnets publics    │  Application Load Balancer │  SG alb : 80 depuis 0.0.0.0/0
  (2 AZ)             └─────────────┬──────────────┘
                                   │ target group, health check GET / toutes les 15 s
               ┌───────────────────┴───────────────────┐
  Subnets      │ EC2 (AZ a)                 EC2 (AZ b) │  Auto Scaling Group
  privés       │ Docker → prestashop:8-apache    …     │  SG app : 80 depuis SG alb
  (2 AZ)       └───────────────────┬───────────────────┘
                                   │ MySQL 3306
                     ┌─────────────▼──────────────┐
                     │ RDS MySQL 8.0 (Multi-AZ    │  SG database : 3306 depuis SG app
                     │ en prod)                   │
                     └────────────────────────────┘
  Hors VPC : Secrets Manager (identifiants RDS), S3 (state Terraform)
  Sortie Internet des subnets privés : NAT Gateway → Internet Gateway
```

### Pourquoi ce placement

| Composant | Où | Justification |
|---|---|---|
| PrestaShop | **EC2** dans un ASG | Le sujet exige au moins une instance EC2 configurée par Ansible. L'ASG ajoute le scaling horizontal et le remplacement automatique |
| Base de données | **RDS** (managé) | Sauvegardes, correctifs et failover Multi-AZ sont fournis par AWS. La base, avec état, reste hors du scaling applicatif, sans état |
| Point d'entrée | **ALB** | Répartit la charge, retire les instances malades et donne un endpoint stable |
| Secret DB | **Secrets Manager** | Terraform génère le mot de passe, Ansible le lit : une seule source de vérité |
| Instances et base | **Subnets privés** | Pas d'IP publique. Seul l'ALB est exposé |

### Gestion du trafic

1. **Répartition** : l'ALB envoie chaque requête à une instance saine du target group.
2. **Scaling** : une politique *target tracking* garde le CPU moyen de l'ASG autour de 60 %. Au-dessus, l'ASG ajoute des instances, jusqu'à `max_size`. En dessous, il en retire, jusqu'à `min_size`.
3. **Panne d'une instance** :
   1. après 3 health checks ratés (environ 45 s), l'ALB ne lui envoie plus de trafic et les autres instances prennent le relais ;
   2. l'ASG, dont le health check est de type `ELB`, la déclare `Unhealthy`, la termine et en relance une nouvelle.
4. **Panne de la base** (en prod, Multi-AZ) : RDS bascule sur la réplique de l'autre AZ en quelques dizaines de secondes.

### Limites (à assumer en soutenance)

- Une instance neuve (scaling ou remplacement) n'est configurée qu'au prochain `terraform apply` suivi d'`ansible-playbook`.
- Il n'y a pas d'EFS : les médias uploadés restent sur chaque instance. Les sessions PHP sont locales.
- Il n'y a pas de cache : RDS est le goulot d'étranglement sous forte charge.
- Une seule NAT Gateway, en HTTP seulement, sans TLS.
- Toutes les limites et leurs pistes d'amélioration sont dans [architecture.md §4](architecture.md#4-limites-connues).

---

## 3. Structure du dépôt

```
.
├── compose.yml                 Floci (émulateur AWS)
├── ansible.cfg                 config Ansible, à la racine pour la séquence de test
├── README.md                   guide d'utilisation (livrable « README »)
├── consignes.md                sujet
├── docs/
│   ├── architecture.md         schéma, limites, plan multi-région
│   └── guide-technique.md      ce document
├── terraform/
│   ├── versions.tf             versions de Terraform et des providers
│   ├── provider.tf             provider AWS pointé sur Floci
│   ├── backend.tf              state distant S3 + verrou
│   ├── variables.tf            paramètres du projet
│   ├── locals.tf               nommage, tags, clé SSH
│   ├── main.tf                 appel des 4 modules
│   ├── ansible.tf              inventaire Ansible écrit dans le state
│   ├── outputs.tf              valeurs exposées (endpoint, ARN…)
│   ├── envs/{dev,staging,prod}.tfvars
│   └── modules/{network,security,compute,database}/
└── ansible/
    ├── requirements.yml        dépendances Galaxy
    ├── inventory.yml           inventaire dynamique
    ├── site.yml                playbook principal
    ├── group_vars/
    │   ├── prestashop.yml      connexion SSH aux instances Floci
    │   └── all/vault.yml       secrets chiffrés (Ansible Vault)
    └── roles/
        ├── prestashop/         notre rôle
        └── geerlingguy.docker/ rôle Galaxy (téléchargé, non versionné)
```

---

## 4. Terraform

### 4.1 Providers

Un **provider** est le plugin qui traduit le code Terraform en appels d'API. Les versions ci-dessous sont celles figées dans `.terraform.lock.hcl`.

| Provider | Version | Sert à | Utilisé dans |
|---|---|---|---|
| `hashicorp/aws` | 6.64.0 (`~> 6.0`) | Créer toutes les ressources AWS (VPC, EC2, ELB, ASG, RDS, Secrets Manager) | Tous les modules, plus la data source d'`ansible.tf` |
| `hashicorp/random` | 3.9.1 (`~> 3.6`) | Générer le mot de passe RDS (`random_password`) sans jamais l'écrire dans le code | `modules/database` |
| `ansible/ansible` | 1.5.0 (`>= 1.0`) | Déclarer des hôtes et groupes Ansible (`ansible_host`, `ansible_group`) qui **n'existent que dans le state** : aucune API n'est appelée | `ansible.tf` |

**`provider.tf`** configure le provider AWS pour Floci :
- identifiants factices `test`/`test` ;
- `skip_credentials_validation`, `skip_metadata_api_check` et `skip_requesting_account_id`, car Floci n'a ni STS réel ni métadonnées ;
- `s3_use_path_style`, car Floci ne gère pas les URL de bucket en sous-domaine ;
- un `endpoints {}` qui redirige chaque service utilisé (ec2, elb, elbv2, autoscaling, rds, secretsmanager, s3, iam, sts) vers `http://localhost.floci.io:4566` ;
- `default_tags`, qui pose `Project`, `Environment` et `ManagedBy` sur chaque ressource.

Pour passer sur un vrai AWS, il suffit de retirer `endpoints`, les `skip_*` et les identifiants en dur.

### 4.2 State distant et verrouillage (`backend.tf`)

- **Où** : le state est stocké dans le bucket S3 `ticket-shop-tfstate`, sous la clé `ticket-shop/terraform.tfstate`.
- **Verrou** : `use_lockfile = true` (Terraform ≥ 1.10) crée un fichier `.tflock` dans S3 pendant chaque opération. Deux `apply` simultanés sont ainsi impossibles, sans table DynamoDB.
- **Versioning** : il est activé sur le bucket (bootstrap du README §4), ce qui permet de revenir à un state précédent.
- **Workspaces** : chaque workspace a son propre state, sous `env:/<workspace>/…` dans le même bucket.

### 4.3 Variables, locals et outputs racine

- **`variables.tf`** :
  - toutes les variables ont une `description` et un type ;
  - `environment` est **validée** (`dev`, `staging` ou `prod`) ;
  - les valeurs par défaut correspondent à `dev`, pour que `terraform apply` sans argument fonctionne.
- **`locals.tf`** :
  - `local.name` vaut `<project>-<env>`, par exemple `ticket-shop-dev`, et préfixe tous les noms ;
  - `local.common_tags` alimente `default_tags` ;
  - `local.ssh_public_key` prend `var.ssh_public_key` s'il est fourni, sinon le contenu de `.keys/ticket_shop.pub`.
- **`outputs.tf`** : `alb_dns_name` (l'endpoint à ouvrir), `asg_name`, `vpc_id`, `db_endpoint` et `db_secret_arn`.

### 4.4 Câblage des modules (`main.tf`)

```
network ──vpc_id, subnet ids──► security ──sg ids──► compute
   │                                 │
   └──private_subnet_ids──► database ◄──database_sg_id
```

Les modules ne se connaissent pas entre eux. `main.tf` passe les **outputs** de l'un en **variables** de l'autre, et Terraform en déduit l'ordre de création. C'est ce que le barème appelle les « références entre ressources ».

### 4.5 Module `network`

| Ressource | Rôle |
|---|---|
| `aws_vpc` | Réseau isolé en `10.0.0.0/16`, avec DNS activé (nécessaire pour résoudre l'endpoint RDS) |
| `aws_subnet.public` ×2 | Un par AZ, pour l'ALB et la NAT. `map_public_ip_on_launch` |
| `aws_subnet.private` ×2 | Un par AZ, pour les EC2 et RDS. Aucune IP publique |
| `aws_internet_gateway` | Sortie et entrée Internet des subnets publics |
| `aws_eip` + `aws_nat_gateway` | Sortie Internet des subnets privés (pour `apt` et `docker pull`), sans les exposer |
| `aws_route_table` et associations | Public : `0.0.0.0/0` → IGW. Privé : `0.0.0.0/0` → NAT |

Le nombre de subnets suit `length(var.azs)` (`count`).

### 4.6 Module `security`

Trois security groups **chaînés par référence** plutôt que par CIDR :

| SG | Entrée autorisée |
|---|---|
| `alb` | TCP 80 depuis `0.0.0.0/0` |
| `app` | TCP 80 **depuis le SG `alb`** uniquement |
| `database` | TCP 3306 **depuis le SG `app`** uniquement |

Une instance ne peut donc pas être jointe directement, et la base n'est accessible qu'aux instances applicatives. Les SG utilisent `name_prefix` et `create_before_destroy`, ce qui permet de les remplacer sans coupure.

Floci enregistre ces règles mais ne les applique pas. Le code reste valable pour AWS.

### 4.7 Module `compute`

| Ressource | Rôle |
|---|---|
| `aws_key_pair` | Injecte la **clé publique** SSH dans les instances, pour Ansible |
| `aws_lb` | ALB public sur les 2 subnets publics |
| `aws_lb_target_group` | Cibles HTTP 80, avec health check `GET /` attendant un code 200 à 399, toutes les 15 s. 2 succès marquent une cible saine, 3 échecs la marquent malade |
| `aws_lb_listener` | Port 80, qui transfère vers le target group |
| `aws_launch_template` | Modèle d'instance : AMI `ami-debian12`, type, clé, SG `app`, tag `Name=<name>-app` |
| `aws_autoscaling_group` | Place les instances dans les subnets privés et les enregistre dans le target group. `health_check_type = "ELB"`, délai de grâce configurable (30 min par défaut) |
| `aws_autoscaling_policy` | Target tracking `ASGAverageCPUUtilization` à 60 % (`cpu_target_value`) |

### 4.8 Module `database`

| Ressource | Rôle |
|---|---|
| `random_password` | 24 caractères, sans caractères spéciaux (sinon, problèmes d'échappement dans la configuration PrestaShop) |
| `aws_db_subnet_group` | Place RDS dans les subnets privés |
| `aws_db_instance` | MySQL 8.0, `db.t3.micro`, 20 Go. `multi_az` selon l'environnement. **Stockage chiffré** (`storage_encrypted`). `skip_final_snapshot`, adapté à un projet de démonstration |
| `aws_secretsmanager_secret` + `_version` | Secret `<name>/rds/master` contenant en JSON `username`, `password`, `host`, `port` et `dbname`. `recovery_window_in_days = 0` permet de redéployer juste après un `destroy` |

### 4.9 Inventaire Ansible (`ansible.tf`)

C'est le pont entre Terraform et Ansible.

1. **Découverte** : la data source `aws_instances` cherche les instances *running* tagguées `Name = <name>-app`. Son `depends_on = [module.compute]` garantit qu'elle est lue après la création de l'ASG. C'est la « data source » attendue par le barème.
2. **Hôtes** : `ansible_host.app` crée un hôte par instance attendue.
   - Les clés vont de `0` à `desired_capacity-1`. Les ids d'instances ne sont connus qu'à l'`apply`, alors que Terraform exige des clés `for_each` connues dès le `plan`.
   - La valeur de chaque hôte est prise avec `element()`.
   - Une `precondition` bloque l'`apply` s'il manque des instances.
   - Variables de chaque hôte : `floci_instance` (id), `private_ip`, `ansible_user=root`, et le **chemin** de la clé privée. Le contenu de la clé finirait sinon dans le state.
3. **Groupe** : `ansible_group.prestashop` transmet ce qu'Ansible doit savoir, à savoir `db_secret_arn`, `db_endpoint`, `db_port`, `alb_dns_name` et `app_environment`. La variable s'appelle `app_environment` parce que `environment` est un mot réservé d'Ansible.

### 4.10 Séparation des environnements

On combine deux mécanismes :

1. **Workspaces** : `default` sert à dev, `staging` et `prod` ont chacun le leur. Chaque workspace a un state séparé, donc un `destroy` en staging ne touche pas la prod.
2. **Fichiers `envs/<env>.tfvars`** : ils fixent la taille (dev 1/2/1 en t3.micro, staging 2/3/2, prod 2/6/2 en t3.small avec RDS Multi-AZ).

De plus, `local.name` contient l'environnement : les noms de ressources ne se heurtent jamais d'un environnement à l'autre. Enfin, `terraform_data.workspace_guard` (`main.tf`) bloque le `plan` si le workspace ne correspond pas à `environment`.

---

## 5. Ansible

### 5.1 Collections et rôles Galaxy (`requirements.yml`)

Les versions sont épinglées, pour un résultat reproductible.

| Dépendance | Type | Version | Sert à |
|---|---|---|---|
| `cloud.terraform` | collection | 4.0.0 | Fournit le plugin d'inventaire **`cloud.terraform.terraform_provider`**, qui lit le state Terraform (`terraform show -json`) et en extrait les ressources `ansible_host` et `ansible_group` |
| `amazon.aws` | collection | 10.1.2 | Fournit le lookup **`amazon.aws.secretsmanager_secret`**, qui lit le secret RDS. Il s'appuie sur `boto3`/`botocore`, côté contrôleur |
| `community.docker` | collection | 4.8.5 | Fournit le module **`community.docker.docker_compose_v2`**, utilisé par le handler pour lancer ou recréer le conteneur. Il appelle le CLI `docker compose`, sans SDK Python sur la cible |
| `geerlingguy.docker` | rôle | 8.0.0 | Rôle Galaxy de référence pour installer Docker Engine et le plugin Compose depuis le dépôt officiel Docker, écrire `daemon.json` et démarrer le service |

`ansible-galaxy install -r ansible/requirements.yml` installe tout cela dans `ansible/collections` et `ansible/roles`, chemins fixés par `ansible.cfg`.

### 5.2 `ansible.cfg` (à la racine)

La séquence de test est lancée depuis la racine, et Ansible ne lit que le `ansible.cfg` du répertoire courant.

| Réglage | Effet |
|---|---|
| `inventory = ansible/inventory.yml` | Inventaire par défaut |
| `roles_path`, `collections_path` | Le projet reste autonome : rien n'est écrit dans `~/.ansible` |
| `enable_plugins = cloud.terraform.terraform_provider` | Un plugin d'inventaire doit être explicitement autorisé |
| `host_key_checking = False` et `ssh_args … UserKnownHostsFile=/dev/null` | Les instances Floci sont éphémères et leur clé d'hôte change. `ControlPersist` réutilise les connexions SSH (plus rapide) |

### 5.3 Inventaire dynamique (`inventory.yml`)

```yaml
plugin: cloud.terraform.terraform_provider
project_path: terraform
```

Le fichier ne contient aucune IP ni aucun nom d'hôte. Le plugin exécute Terraform dans `terraform/`, lit le state (donc le backend S3) et construit le groupe `prestashop` avec ses hôtes `app-0`, `app-1`… On peut le vérifier avec `ansible-inventory --graph`.

### 5.4 Variables

- **`group_vars/prestashop.yml`**, spécifique à Floci :
  - chaque « EC2 » est en fait un conteneur `floci-ec2-<id>` dont le port 22 est publié sur le poste ;
  - `ansible_host` vaut `127.0.0.1` ;
  - `ansible_port` est obtenu dynamiquement par `docker port floci-ec2-<floci_instance> 22/tcp`.

  Sur un vrai AWS, ce fichier disparaîtrait et on passerait par l'IP privée, via un bastion ou SSM.
- **`group_vars/all/vault.yml`** : `vault_ps_admin_mail` et `vault_ps_admin_passwd`, **chiffrés en AES256** par Ansible Vault. Ils sont déchiffrés à l'exécution grâce à `--ask-vault-pass`.
- **`roles/prestashop/defaults/main.yml`** : image `prestashop/prestashop:8-apache`, dossier `/opt/prestashop`, port 80, région et endpoint Floci pour le lookup. Ce sont des valeurs par défaut, faciles à surcharger.

### 5.5 Playbook `site.yml`

```
hosts: prestashop   (groupe venant de Terraform)
gather_facts: false (Python n'est pas encore installé)
become: true
vars: Docker avec plugin Compose, storage-driver vfs (contrainte Floci)

pre_tasks:
  1. raw : installe python3 s'il manque   (changed seulement s'il l'installe)
  2. setup : collecte les facts
roles:
  3. geerlingguy.docker   (Galaxy)
  4. prestashop           (maison)
```

### 5.6 Rôle `prestashop`

**Tâches** (`tasks/main.yml`) :

1. **Créer `/opt/prestashop`** (mode `0750`).
2. **Lire le secret RDS** avec `set_fact` et le lookup `amazon.aws.secretsmanager_secret`, à partir de `db_secret_arn`. Le lookup s'exécute sur le **contrôleur**, et `no_log: true` empêche toute fuite dans les logs.
3. **Générer `force-host.conf`** depuis un template Jinja2, puis **notifier** le handler.
4. **Générer `docker-compose.yml`** depuis un template (avec `no_log`, car il contient le mot de passe), puis **notifier** le handler.
5. **Vérifier le conteneur** avec `docker inspect`. S'il est absent ou arrêté (run précédent interrompu), une tâche notifie le handler malgré tout.
6. **`flush_handlers`** : le redéploiement a lieu tout de suite, et non en fin de play.
7. **Attendre l'application** : `uri`, exécuté sur l'instance, réessaie jusqu'à 15 min que `/` et `/admin-ticketshop/` répondent 200. Le playbook ne réussit donc que si PrestaShop fonctionne vraiment.
8. **Afficher les URL** de la boutique et du back-office.

**Templates** :
- **`docker-compose.yml.j2`** définit le service `prestashop` :
  - variables `DB_SERVER`, `DB_PORT`, `DB_NAME`, `DB_USER` et `DB_PASSWD`, qui viennent du secret ;
  - `PS_INSTALL_AUTO=1` : PrestaShop s'installe tout seul dans RDS au premier démarrage ;
  - `PS_DOMAIN` vaut le DNS de l'ALB ;
  - identifiants admin tirés du Vault ;
  - `PS_FOLDER_ADMIN=admin-ticketshop` : l'image renomme `admin/` avant l'installation. Avec la valeur `admin`, l'installeur choisirait un nom aléatoire ;
  - port lié sur l'IP privée de l'instance ;
  - volume `prestashop_data` pour les fichiers.
- **`force-host.conf.j2`** : `RequestHeader set Host "<alb_dns_name>" early`. L'ALB de Floci réécrit l'en-tête `Host`, ce qui faisait boucler la redirection de PrestaShop. La directive `early` s'applique avant `mod_rewrite`. `ServerName` et `UseCanonicalName On` font que les redirections générées par Apache (`/admin-ticketshop` → `/admin-ticketshop/`) pointent vers l'ALB, et non vers l'IP privée.

**Handler** (`handlers/main.yml`) : `Redéployer PrestaShop` appelle `docker_compose_v2` avec `recreate: always`. **Il ne s'exécute que s'il a été notifié**, c'est-à-dire si un fichier a changé ou si le conteneur est absent.

### 5.7 Pourquoi le second passage donne `changed=0`

| Tâche | Au 2ᵉ passage |
|---|---|
| `raw` python3 | `changed` seulement si Python vient d'être installé (marqueur `PYTHON_BOOTSTRAPPED`) |
| `geerlingguy.docker` | Paquets déjà installés, service déjà démarré : `ok` |
| `file`, `template` | Contenu identique : `ok` |
| `set_fact`, `command docker inspect` | Jamais `changed` (`changed_when: false`) |
| `debug` « forcer le redéploiement » | Sautée, car le conteneur tourne |
| Handler | Non notifié, donc non exécuté |
| `uri` (attente) et `debug` (URL) | Ne modifient rien : `ok` |

---

## 6. Circuit des secrets

```
Terraform random_password ──► aws_db_instance (password)
                          └─► Secrets Manager <name>/rds/master (JSON)
                                       │ ARN seulement
                                       ▼
                   state Terraform ─► ansible_group.prestashop.db_secret_arn
                                       │
Ansible (contrôleur) lookup secretsmanager_secret(ARN) ─► prestashop_db_creds (no_log)
                                       │
                                       ▼
                    template docker-compose.yml (0640, no_log) ─► conteneur

Ansible Vault vault.yml (chiffré) ──--ask-vault-pass──► ADMIN_MAIL / ADMIN_PASSWD
Clé SSH : .keys/ (gitignoré). Publique → Terraform ; privée → chemin seulement.
```

Le dépôt ne contient ni mot de passe, ni clé privée, ni IP. Les seuls identifiants en dur sont `test`/`test`, les identifiants factices de Floci, qui ne sont vérifiés nulle part.

---

## 7. Correspondance avec le barème

| Critère (points) | Où / comment c'est satisfait |
|---|---|
| **App déployée et accessible (3)** | L'ALB transmet à PrestaShop sur les EC2. Endpoint : `terraform output alb_dns_name` |
| **Connectée à une base (3)** | RDS MySQL. `PS_INSTALL_AUTO` y crée le schéma et le catalogue de démonstration |
| **EC2 via Terraform + Ansible (2)** | Launch template et ASG (`compute`), configurés par `site.yml` |
| **Redéployable depuis l'automatisation (2)** | Bootstrap du README §4, puis les 6 commandes. Clé SSH lue automatiquement, valeurs par défaut sans prompt |
| **Architecture cohérente et trafic justifié (2)** | ALB, ASG en target tracking CPU, RDS Multi-AZ. README §1–2, `architecture.md` |
| **Organisation, modules, variables, descriptions, outputs (2)** | 4 modules, chacun avec `variables.tf` et `outputs.tf`, et une description sur chaque variable et chaque output |
| **Séparation des environnements (1)** | Workspaces, `envs/*.tfvars`, `local.name`, validation de `environment` |
| **State distant, verrou, data sources, références (1)** | Backend S3 avec `use_lockfile`, data source `aws_instances`, outputs de modules passés en entrée des autres |
| **Réseau sécurisé et secrets (1)** | Subnets privés, SG chaînés, NAT, RDS chiffré, Secrets Manager, `random_password` |
| **Inventaire dynamique depuis Terraform (2)** | `ansible.tf` combiné au plugin `cloud.terraform.terraform_provider` |
| **Rôles réutilisables et Galaxy (1)** | Rôle `prestashop` paramétré par `defaults`, plus `geerlingguy.docker` et 3 collections |
| **Vault et secrets (1)** | `vault.yml` chiffré, `no_log`, secret RDS hors du Vault |
| **Idempotence, templates, handlers (2)** | 2 templates notifiant 1 handler. Second passage à `changed=0` (§5.7). Le playbook attend que l'application réponde |
| **README clair et reproductible (2), concis (1), choix de placement (1)** | README en 9 sections, avec un bootstrap copiable et un tableau de placement dans `architecture.md` |
| **Présentation (3)** | Ce guide (§1, §2 et §7) sert de trame |

---

## 8. Spécificités Floci à connaître pour la démo

| Symptôme | Cause | Traitement |
|---|---|---|
| Les SG ne bloquent rien | Floci ne filtre pas le trafic | Documenté. Le code reste correct pour AWS |
| Boucle de redirection infinie | L'ALB réécrit `Host` | `force-host.conf` |
| Erreur Docker *whiteout* | Docker-in-Docker avec overlay2 | `storage-driver: vfs` |
| IP privée injoignable en SSH | Les instances sont des conteneurs | `127.0.0.1` et `docker port` |
| Conflit sur le port 80 | Service de métadonnées de Floci | Bind sur l'IP privée |
| Tout disparaît après un redémarrage de Floci | Aucune persistance | Refaire le bootstrap et l'`apply` |
| `plan` jamais vide après `apply` | `enabled` des scaling policies et tags de la key pair non conservés | Laissé visible, volontairement |
