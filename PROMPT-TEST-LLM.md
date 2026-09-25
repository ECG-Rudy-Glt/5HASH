Tu es l'évaluateur du projet « Taylor Shift's Ticket Shop » (module 5HASH, Supinfo). Tu travailles dans le dépôt courant, avec un accès shell. Ta mission : **déployer l'application en suivant uniquement le README**, vérifier qu'elle fonctionne, puis **noter le projet selon le barème** de `consignes.md`, preuves à l'appui.

## Règles

1. **Lis d'abord** `consignes.md`, `README.md`, `terraform/README.md`, `ansible/README.md` et `docs/architecture.md`. Les instructions qui comptent sont celles du README. N'utilise ta connaissance du code que pour expliquer un échec, jamais pour le contourner en silence.
2. **Ne modifie aucun fichier du dépôt.** Si une étape échoue :
   - note la commande, la sortie d'erreur et ton diagnostic ;
   - tu peux appliquer un contournement *hors dépôt* (variable d'environnement, commande supplémentaire) pour continuer, mais signale-le comme un écart au README et pénalise le critère concerné.
3. **Floci est un service partagé** sur cette machine :
   - ne lance pas `docker compose down`, ne redémarre pas et ne recrée pas le conteneur Floci sans me demander ;
   - ne supprime aucune ressource AWS qui ne porte pas le tag `Project=ticket-shop`.
4. **Commandes longues** : l'installation de Docker et le premier démarrage de PrestaShop prennent plusieurs minutes. Utilise des timeouts généreux (≥ 20 min pour le premier playbook) et ne conclus pas à un échec trop tôt.
5. **Mot de passe Vault** : la séquence officielle utilise `--ask-vault-pass`, qui est interactif.
   - Si tu ne peux pas saisir de mot de passe, demande-le-moi, ou utilise `--vault-password-file .vault-pass` si ce fichier existe.
   - Signale cette substitution : elle est équivalente et n'est pas pénalisable.
6. **Log** : conserve chaque commande et le résumé de sa sortie (code retour, lignes utiles, `PLAY RECAP`).

## Étape 1 — Contrôles statiques (sans rien déployer)

- `terraform -chdir=terraform fmt -check -recursive` et `terraform -chdir=terraform validate`.
- `ansible-playbook --syntax-check ansible/site.yml` et `ansible-lint ansible/site.yml`. Ignore les remarques sur `ansible/roles/geerlingguy.docker`, qui est un code tiers.
- **Secrets en clair** : cherche mots de passe, clés privées et IP dans les fichiers versionnés (`git ls-files`). `test`/`test` sont les identifiants factices de Floci et sont acceptés. Vérifie que `ansible/group_vars/all/vault.yml` commence par `$ANSIBLE_VAULT`.
- **Qualité du code** : chaque variable et chaque output Terraform a-t-il une `description` ? Les modules sont-ils séparés ? Liste les manques.

## Étape 2 — Prérequis et mise en place (README §3 et §4)

- **Versions** : vérifie Terraform ≥ 1.10, `ansible-core` ≥ 2.15, la présence de `boto3` dans l'environnement Python d'Ansible, l'AWS CLI et Docker.
- **Floci** : s'il tourne déjà (`docker ps`), ne le relance pas. Sinon, `docker compose up -d`.
- **Clé SSH** : génère-la si `.keys/ticket_shop` n'existe pas.
- **Bucket du backend** : crée-le exactement comme au README §4. Si le bucket existe déjà, note-le et continue.

## Étape 3 — Séquence de test officielle, à l'identique

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply            # confirme par "yes", SANS -var ni -var-file
ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
```

Points à vérifier :
- `apply` ne doit **poser aucune question** en dehors de la confirmation.
- `--graph` doit afficher un groupe `prestashop` avec au moins un hôte.
- Le **premier** playbook doit finir avec `failed=0 unreachable=0`.
- Le **second** doit afficher `changed=0` sur tous les hôtes. S'il y a des changements, liste les tâches concernées et dis si elles sont « inattendues ».

## Étape 4 — Vérification fonctionnelle

1. **Endpoint** : `terraform -chdir=terraform output -raw alb_dns_name`, puis `curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://<dns>/`. On attend un code 200, sans boucle de redirection.
2. **Contenu** : récupère la page d'accueil et vérifie qu'il s'agit bien de PrestaShop, avec le catalogue de démonstration (des noms de produits).
3. **Connexion à la base**, à prouver par au moins deux moyens :
   - le catalogue affiché vient de RDS ;
   - `terraform output db_endpoint` répond, et le back-office `/admin-ticketshop/` (URL affichée à la fin du playbook) montre la page de connexion ;
   - le conteneur a `DB_SERVER` égal à l'endpoint RDS. Par exemple : `ansible prestashop -i ansible/inventory.yml -b -m command -a "docker exec prestashop-prestashop-1 printenv DB_SERVER"` (avec le mot de passe Vault).
4. **Résistance aux pannes (facultatif)** : arrête le conteneur PrestaShop d'une instance (`docker stop`) et observe l'état du target group (`aws elbv2 describe-target-health` avec l'endpoint Floci). Puis relance le playbook et vérifie qu'il répare. Compare avec ce que le README annonce au §2.

## Étape 5 — Environnements (sans tout déployer)

- `terraform -chdir=terraform workspace new staging`, puis `terraform -chdir=terraform plan -var-file=envs/staging.tfvars`.
- Vérifie que les noms contiennent `ticket-shop-staging`, que la capacité est de 2/3/2, et que le state est isolé.
- N'applique **pas**. Reviens ensuite sur le workspace `default`.

## Étape 6 — Rapport final

Rends un rapport en français, structuré ainsi :

1. **Résumé** : l'application tourne-t-elle, oui ou non ? Endpoint testé et note estimée sur 30.
2. **Journal d'exécution** : tableau avec la commande, le résultat (OK / KO / écart) et une preuve courte.
3. **Notation** : un tableau reprenant **chaque ligne du barème** de `consignes.md`. Pour chacune, donne les points obtenus sur les points possibles, une justification et une preuve (sortie de commande, fichier et ligne). Pour la « Présentation (3 pts) », indique « non évaluable » et donne seulement des conseils.
4. **Écarts au README** : chaque endroit où tu as dû dévier, deviner, ou où le README était faux ou incomplet.
5. **Problèmes classés par gravité** (bloquant, majeur, mineur), avec une correction proposée. Ne l'applique pas.
6. **Nettoyage** : ne lance **pas** `terraform destroy` sans mon accord. Indique la commande à utiliser.
