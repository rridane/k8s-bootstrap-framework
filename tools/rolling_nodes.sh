#!/usr/bin/env bash
# rolling_nodes.sh — joue une étape du runner NŒUD PAR NŒUD, avec validation entre chaque.
#
#   tools/rolling_nodes.sh <tag> <inventaire> <motif d'hôtes> [args ansible...]
#
#   ex : KUBECONFIG=~/.kube/config tools/rolling_nodes.sh upgrade:kubeadm_nodes_workers \
#          inventories/<cible>/host.ini 'workers:!worker-0' -e k8s_upgrade_version=1.28.15
#
# Pour chaque hôte du motif (ordre de l'inventaire) :
#   état du nœud → ./cluster <tag> --limit <hôte> (plan → confirmation → apply) → état → « continuer ? »
# Le mot de passe sudo est demandé UNE fois (fichier temporaire 0600, supprimé à la sortie),
# sauf si BECOME_PASSWORD_FILE est fourni (appel depuis kubeadm_upgrade_minor.sh).
# Un échec du runner arrête le script ; le nœud en cours reste tel que le rôle l'a laissé.
# KUBECONFIG (optionnel) : affiche l'état du nœud (Ready, version kubelet, cordon) et les pods Pending,
#   et SAUTE les nœuds déjà à la cible (Ready, kubelet = -e k8s_upgrade_version, non cordonnés) :
#   relancer après une interruption reprend au premier nœud restant.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 3 ]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
TAG=$1 INV=$2 PATTERN=$3
shift 3
EXTRA=("$@")

mapfile -t NODES < <(.venv/bin/ansible "$PATTERN" -i "$INV" --list-hosts 2>/dev/null | tail -n +2 | awk '{print $1}')
if [ ${#NODES[@]} -eq 0 ]; then
  echo "Aucun hôte pour le motif '$PATTERN' dans $INV." >&2
  exit 1
fi

# Version visée, lue dans les args (-e k8s_upgrade_version=x.y.z) : sert à sauter les nœuds déjà faits.
TARGET=""
for a in "${EXTRA[@]}"; do
  [[ $a =~ k8s_upgrade_version=v?([0-9]+\.[0-9]+\.[0-9]+) ]] && TARGET="v${BASH_REMATCH[1]}"
done

done_already() {  # Ready, kubelet à la cible, non cordonné
  [ -n "$TARGET" ] && [ -n "${KUBECONFIG:-}" ] && command -v kubectl >/dev/null || return 1
  [ "$(kubectl get node "$1" -o 'jsonpath={.status.nodeInfo.kubeletVersion}|{.spec.unschedulable}|{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = "$TARGET||True" ]
}

TODO=()
for n in "${NODES[@]}"; do
  if done_already "$n"; then echo "déjà en $TARGET, sauté : $n"; else TODO+=("$n"); fi
done
if [ ${#TODO[@]} -eq 0 ]; then
  echo "Rien à faire : tous les nœuds de '$PATTERN' sont déjà en $TARGET."
  exit 0
fi
NODES=("${TODO[@]}")

echo "Étape  : $TAG${TARGET:+ → $TARGET}"
echo "Nœuds  : ${NODES[*]} (${#NODES[@]})"
[ ${#EXTRA[@]} -gt 0 ] && echo "Args   : ${EXTRA[*]}"
echo

# BECOME_PASSWORD_FILE (optionnel) : fichier du mot de passe sudo fourni par un script appelant.
if [ -n "${BECOME_PASSWORD_FILE:-}" ]; then
  PWF=$BECOME_PASSWORD_FILE
else
  read -rsp "Mot de passe sudo (become) : " BPW; echo
  PWF=$(mktemp)
  chmod 600 "$PWF"
  trap 'rm -f "$PWF"' EXIT
  printf '%s\n' "$BPW" > "$PWF"
  unset BPW
fi

state() {
  [ -n "${KUBECONFIG:-}" ] && command -v kubectl >/dev/null || return 0
  # Lecture seule : une erreur passagère de l'API (ou du proxy Rancher) ne doit pas arrêter le script.
  kubectl get node "$1" -o custom-columns=NOEUD:.metadata.name,READY:.status.conditions[-1].status,KUBELET:.status.nodeInfo.kubeletVersion,CORDON:.spec.unschedulable 2>/dev/null \
    || echo "(état de $1 indisponible : API ou proxy momentanément injoignable)"
  echo "Pods Pending (cluster) : $(kubectl get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null | wc -l || true)"
}

i=0
for n in "${NODES[@]}"; do
  i=$((i + 1))
  echo
  echo "════════ [$i/${#NODES[@]}] $n ════════"
  state "$n"
  ./cluster "$TAG" "$INV" --become-password-file "$PWF" --limit "$n" "${EXTRA[@]}"
  echo
  echo "── état après $n :"
  state "$n"
  if [ $i -lt ${#NODES[@]} ]; then
    read -rp "Continuer avec ${NODES[$i]} ? [o/N] " a
    [[ $a =~ ^[oOyY] ]] || { echo "Arrêt demandé après $n."; exit 0; }
  fi
done
echo
echo "Terminé : ${#NODES[@]} nœud(s)."
