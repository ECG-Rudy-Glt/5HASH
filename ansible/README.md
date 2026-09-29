# Ansible : Taylor Shift's Ticket Shop

Ansible configure les instances provisionnées par Terraform et y déploie PrestaShop (image Docker Hub `prestashop/prestashop:8-apache`), connecté à RDS. Pour la séquence de lancement, voir le [README racine, section 5](../README.md#5-déploiement).

## 1. Structure

```
ansible.cfg                  à la racine du dépôt (voir section 2)
ansible/
  requirements.yml           collections et rôle Galaxy, versions épinglées
  inventory.yml              déclare le plugin d'inventaire dynamique
  site.yml                   playbook principal
  group_vars/
    prestashop.yml           accès SSH aux instances Floci
    all/vault.yml            identifiants admin PrestaShop (chiffrés par Vault)
  roles/
    prestashop/              notre rôle : defaults, tasks, templates, handlers
    geerlingguy.docker/      installé depuis Galaxy (gitignoré)
```

## 2. Pourquoi `ansible.cfg` est à la racine

La séquence de test s'exécute depuis la racine du dépôt, et Ansible ne lit que le `ansible.cfg` du répertoire courant. Ce fichier :

- autorise le plugin `cloud.terraform.terraform_provider` (`enable_plugins`) ;
- redirige `roles_path` et `collections_path` vers `ansible/`, pour ne pas toucher au `~/.ansible` global.

Si `ANSIBLE_CONFIG` est défini dans le shell, il est prioritaire sur ce fichier : dans ce cas, faire `unset ANSIBLE_CONFIG`.

## 3. Inventaire dynamique

[inventory.yml](inventory.yml) ne contient que `plugin: cloud.terraform.terraform_provider` et `project_path: terraform`. Hôtes et variables viennent du state Terraform ([terraform/ansible.tf](../terraform/ansible.tf)) :

- **par hôte** : `floci_instance` (id de l'instance), `private_ip`, et le **chemin** de la clé SSH privée (jamais son contenu) ;
- **groupe `prestashop`** : `db_secret_arn`, `db_endpoint`, `db_port`, `alb_dns_name`, `app_environment`.

L'inventaire est mis à jour à chaque `terraform apply`.

## 4. Secrets

| Secret | Où il vit | Comment Ansible l'obtient |
|---|---|---|
| Identifiants RDS | AWS Secrets Manager (créé par Terraform) | Lookup `amazon.aws.secretsmanager_secret` à partir du seul ARN transmis par l'inventaire |
| Identifiants admin PrestaShop | [group_vars/all/vault.yml](group_vars/all/vault.yml), chiffré | Ansible Vault (`--ask-vault-pass`) |

- **Mot de passe Vault versionné exprès** : il est dans `.vault-pass`, à la racine, pour que l'évaluatrice puisse lancer le playbook (voir [README racine §4](../README.md#4-mise-en-place-à-faire-une-fois-avant-la-séquence-de-test)). Hors contexte d'évaluation, ce fichier serait gitignoré.
- **Pas de copie** : le mot de passe RDS n'est jamais recopié dans Vault.
- **Lookup local** : il s'exécute sur le contrôleur. `boto3` et `botocore` doivent donc être installés dans l'environnement Python d'Ansible (`pipx inject ansible-core boto3 botocore`), pas sur les instances.
- **`no_log: true`** : il est posé sur les tâches qui manipulent un secret déchiffré, pour qu'il n'apparaisse ni dans les logs ni dans `--diff`.

## 5. Playbook et rôle `prestashop`

`site.yml` :

1. installe Python avec `raw` si besoin (l'image Debian n'en a pas), puis collecte les facts ;
2. applique le rôle Galaxy `geerlingguy.docker` ;
3. applique le rôle `prestashop`.

Le rôle `prestashop` :

1. crée `/opt/prestashop` ;
2. lit le secret RDS ;
3. génère `force-host.conf` et `docker-compose.yml` à partir de leurs templates, puis **notifie** le handler `Redéployer PrestaShop` ;
4. vérifie que le conteneur tourne. Sinon, par exemple après un run interrompu, il force le handler ;
5. exécute tout de suite le handler (`flush_handlers`), puis attend que `/` et `/admin-ticketshop/` répondent 200 (`uri`, jusqu'à 15 min) ;
6. affiche les URL de la boutique et du back-office.

**Idempotence** : le handler ne s'exécute que si un template a changé ou si le conteneur est absent. Le second passage doit donc afficher `changed=0`.

## 6. Limites dues à Floci

- **Docker en `vfs`** : les instances Floci sont elles-mêmes des conteneurs, et `overlay2` échoue en Docker-in-Docker (erreur *whiteout*). `fuse-overlayfs` est bloqué au montage FUSE. `vfs` est plus lent mais fonctionne. Sur un vrai EC2, `overlay2` suffit.
- **Accès SSH** : l'IP privée n'est pas joignable depuis le poste. [group_vars/prestashop.yml](group_vars/prestashop.yml) se connecte donc à `127.0.0.1`, sur le port SSH que Floci publie pour chaque instance (`docker port`). Sur AWS, `ansible_host` serait l'IP privée, via un bastion.
- **Port 80 lié à l'IP privée, pas à `0.0.0.0`** : sinon, conflit avec le service de métadonnées interne de Floci.
- **Header `Host` réécrit par l'ALB** : corrigé par `force-host.conf`, qui fixe aussi `ServerName` pour que les redirections d'Apache ne renvoient pas vers l'IP privée. Voir [terraform/README.md, section 4](../terraform/README.md#4-limites-dues-à-floci).
- **Clés d'hôte SSH non vérifiées** (`ansible.cfg`), parce que les instances sont éphémères. À réactiver sur des instances durables.
