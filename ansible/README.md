# Ansible — Taylor Shift's Ticket Shop

Configuration des instances provisionnées par Terraform et déploiement de PrestaShop (image Docker Hub générique), connecté à la base RDS.

## 1. Principe : rien n'est écrit à la main

L'inventaire, les adresses, les identifiants de base de données : rien de tout ça n'est saisi manuellement. Terraform décrit l'inventaire directement dans son state ([`terraform/ansible.tf`](../terraform/ansible.tf), ressources `ansible_host`/`ansible_group`), et [`ansible/inventory.yml`](inventory.yml) se contente de déclarer le greffon `cloud.terraform.terraform_provider` qui va le lire. Si l'Auto Scaling Group remplace une instance, l'inventaire suit automatiquement au prochain `terraform apply`.

## 2. Structure

```
ansible.cfg                  # à la racine du dépôt (pas dans ansible/) — voir §3
ansible/
  requirements.yml           # collections + rôle Galaxy, épinglés
  inventory.yml               # déclare le greffon d'inventaire dynamique
  site.yml                     # playbook principal
  group_vars/
    prestashop.yml              # comment joindre les instances (port SSH publié par Floci)
    all/vault.yml                 # secret applicatif chiffré (Ansible Vault)
  roles/
    prestashop/                   # notre rôle
    geerlingguy.docker/           # installé depuis Galaxy (gitignored)
```

## 3. Pourquoi `ansible.cfg` est à la racine du dépôt

La séquence de test de l'énoncé s'exécute **depuis la racine**, jamais depuis `ansible/` :

```sh
ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
```

Ansible ne cherche `ansible.cfg` que dans le répertoire courant (`./ansible.cfg`) — il doit donc être à la racine pour être détecté automatiquement, pas dans `ansible/`. C'est lui qui : autorise explicitement le greffon d'inventaire (`enable_plugins`, un greffon doit toujours être déclaré), et redirige `roles_path`/`collections_path` vers `ansible/roles`/`ansible/collections` (projet auto-contenu, pas de pollution du `~/.ansible` global).

> ⚠️ Si une variable d'environnement `ANSIBLE_CONFIG` est déjà définie dans ton shell, elle prend le pas sur ce fichier quel que soit le répertoire courant. Vérifier avec `ansible-config dump --only-changed | grep CONFIG_FILE`, et `unset ANSIBLE_CONFIG` si besoin.

## 4. L'inventaire dynamique

[`terraform/ansible.tf`](../terraform/ansible.tf) déclare :
- `ansible_host` (un par instance de l'ASG) : porte `floci_instance` (l'ID réel), `private_ip`, et le **chemin** (jamais le contenu) de la clé SSH privée.
- `ansible_group "prestashop"` : porte ce que Terraform sait et qu'Ansible ignore — l'ARN du secret RDS, l'endpoint/port de la base, le nom DNS de l'ALB.

Contrainte spécifique à un Auto Scaling Group (pas des `aws_instance` fixes) : les IDs d'instances ne sont connus qu'à l'`apply`, donc impossible de faire un `for_each` direct dessus (« Invalid for_each argument »). La ressource utilise des **clés statiques** (`0`, `1`, ... selon `desired_capacity`) et ne laisse que la **valeur** dépendre de l'apply, via `element()`.

## 5. Les deux secrets, deux mécanismes

| Secret | Origine | Où il vit | Comment Ansible l'obtient |
|---|---|---|---|
| Mot de passe RDS | Généré par Terraform (`random_password`) | AWS Secrets Manager | Lookup `amazon.aws.secretsmanager_secret` (voir [`roles/prestashop/tasks/main.yml`](roles/prestashop/tasks/main.yml)), à partir du seul ARN transmis par l'inventaire |
| Identifiants admin PrestaShop | Appartiennent au dépôt Ansible | [`group_vars/all/vault.yml`](group_vars/all/vault.yml), chiffré | Ansible Vault (`--ask-vault-pass` / `--vault-password-file`) |

Le mot de passe RDS n'est **jamais** dupliqué dans Vault — one endroit, une seule source de vérité. Le lookup Secrets Manager s'exécute sur le **contrôleur** (ce poste), pas sur l'instance distante : `boto3`/`botocore` doivent donc être installés localement (`sudo apt install python3-boto3 python3-botocore`), pas sur les EC2.

`no_log: true` est posé sur toute tâche qui manipule un secret déchiffré : Vault protège la valeur *stockée*, pas la valeur *utilisée* — une fois déchiffrée, elle traverserait sinon les logs et le `--diff`.

## 6. Le rôle `prestashop`

1. Crée le répertoire de l'application.
2. Lit le secret RDS (Secrets Manager).
3. Template [`docker-compose.yml.j2`](roles/prestashop/templates/docker-compose.yml.j2) avec les identifiants DB + Vault → **notifie** le handler `Redéployer PrestaShop`.
4. Le handler ne s'exécute **que si le template a changé** — c'est ce qui garantit l'idempotence : rien à faire, rien ne se redéploie.

Le port du conteneur est publié sur l'**IP privée précise de l'instance**, jamais `0.0.0.0` (cf. commentaire dans le template) — une écoute large entre en conflit avec le service de métadonnées interne de Floci.

## 7. Lancer

```sh
docker compose up -d                                    # Floci
cd terraform && terraform apply && cd ..                # infra + inventaire

ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph

ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # doit annoncer 0 changement
```

## 8. Limites connues (environnement Floci, pas le code)

- **Driver de stockage Docker forcé en `vfs`** : les instances Floci sont elles-mêmes des conteneurs Docker ; `overlay2` (le défaut) casse sur certaines images en imbriqué (erreur `whiteout file`). `fuse-overlayfs` (solution standard pour Docker-in-Docker, plus rapide) a été testée mais le montage FUSE reste bloqué dans ce conteneur — probablement une capacité refusée. `vfs` (copies complètes, plus lent mais fiable) est donc la seule option qui fonctionne ici. Sur un vrai EC2, aucun des deux ne serait nécessaire.
- **Image Debian minimale sans Python** : bootstrap via `ansible.builtin.raw` en `pre_tasks`, seul module qui n'en a pas besoin.
- **Pas de vrai firewall** : les security groups sont déclarées correctement (portables vers un vrai AWS) mais Floci ne les applique pas réellement — voir [`terraform/modules/security/main.tf`](../terraform/modules/security/main.tf).
