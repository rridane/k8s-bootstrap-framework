# Inventaire de référence

Toutes les options configurables du framework, auto-documentées. **Copie ce dossier**
pour une nouvelle cible et garde les fichiers/options utiles.

## Modèle
- `host.ini` : les groupes conventionnels ciblés par le catalog.
- `group_vars/all/NN_<étape>.yml` : un fichier par étape. Le **numéro** = position
  dans la timeline (cf. `catalog/`), le **nom** = la tâche du catalog.
  - `prepare_<x>` = étape de **prépa** (partagée par les distros) : flag `prepare_<x>`
    + toutes les options du/des rôle(s) (commentées = valeurs par défaut).
  - `bootstrap_<distro>_<x>` = étape qui **amorce/joint** un nœud, spécifique à la distro
    (`bootstrap_rke2_server` / `bootstrap_rke2_agent` / `bootstrap_kubeadm_<x>`) : flag + config.
  - `configure_<distro>_<x>` = étape qui **génère un manifeste** dans `server/manifests/`
    (RKE2 l'applique au start), elle n'amorce rien : `configure_rke2_cilium`,
    `configure_rke2_kubevip`.

## Activer une étape
Mettre son flag à `true` (ex. `prepare_proxy: true`, `configure_rke2_kubevip: true`)
et surcharger les options voulues. Une étape dont le flag n'est pas `true` est
**skippée** (défaut `false`).

## Lancer une seule étape (tag)
Chaque étape a un tag `<action>:<distro_>step` : `-t prepare:proxy`, `-t clean:proxy`,
`-t configure:rke2_kubevip`, `-t bootstrap:rke2_primary`, `-t clean:rke2_agent`.

## Jouer
```sh
# prépa (installer / réverser)
ansible-playbook -i inventories/<cible>/host.ini playbooks/prepare.yaml -t prepare
ansible-playbook -i inventories/<cible>/host.ini playbooks/prepare.yaml -t clean
# bootstrap
ansible-playbook -i inventories/<cible>/host.ini playbooks/bootstrap/rke2_bootstrap.yaml
# teardown
ansible-playbook -i inventories/<cible>/host.ini playbooks/clean/rke2_clean.yaml
```

## Secrets
Tout ce qui est marqué `# VAULTER` → `group_vars/all/vault.yml` chiffré
(`ansible-vault encrypt`), jamais en clair. Modèle : `vault.yml.example`.
