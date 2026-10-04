#!/usr/bin/env bash
# kubeadm_upgrade_minor.sh — monte un cluster kubeadm d'UNE mineure, de bout en bout, en
# demandant validation avant chaque étape et entre chaque nœud.
#
#   KUBECONFIG=<kubeconfig du cluster> tools/kubeadm_upgrade_minor.sh <inventaire> <x.y.z> [groupe_legacy]
#
#   ex : tools/kubeadm_upgrade_minor.sh inventories/<cible>/host.ini 1.29.15 workers_bionic
#
# Étapes (chacune : o = lancer, s = sauter, autre = arrêter) :
#   0. contrôles  : nœuds Ready, aucun cordon, aucune pression (disque/mémoire/PID), etcd sain,
#                   kubelets au plus une mineure sous la cible (exigence de kubeadm)
#   1. prepare    : upgrade:kubeadm_prepare sur tous les masters (kubeadm, images, plan) — rien d'appliqué
#   2. control plane : upgrade:kubeadm_control_plane, master par master (primaire d'abord)
#   3. kubelets masters : rolling_nodes.sh upgrade:kubeadm_nodes_masters
#   4. kubelets workers : rolling_nodes.sh upgrade:kubeadm_nodes_workers
#   5. groupe_legacy (optionnel) : nœuds hors d'atteinte des modules Ansible (ex. Python trop
#                   ancien) — drain, paquets via le module raw, kubeadm upgrade node, restart, uncordon
#   6. état final
# Le mot de passe sudo est demandé une fois. Rejouable : les nœuds déjà à la cible sont sautés.
# Prérequis : la clé du dépôt pkgs.k8s.io posée sur chaque nœud (README de k8s_upgrade_packages).
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; }
if [ $# -lt 2 ]; then usage; exit 1; fi
INV=$1
VERSION=${2#v}
LEGACY=${3:-}
[[ $VERSION =~ ^([0-9]+)\.([0-9]+)\.[0-9]+$ ]] || { echo "Version attendue x.y.z, reçu '$2'." >&2; exit 1; }
MINOR=${BASH_REMATCH[2]}
SERIES="v${BASH_REMATCH[1]}.$MINOR"
TARGET="v$VERSION"
[ -n "${KUBECONFIG:-}" ] || { echo "KUBECONFIG doit pointer sur le cluster." >&2; exit 1; }
ANSIBLE=${ANSIBLE:-.venv/bin/ansible}
EV=(-e "k8s_upgrade_version=$VERSION")

hosts() { "$ANSIBLE" "$1" -i "$INV" --list-hosts 2>/dev/null | tail -n +2 | awk '{print $1}'; }
ask() {  # ask "question" → 0 = oui, 1 = sauter ; arrête sinon
  local a
  read -rp "$1 [o = oui / s = sauter / autre = arrêter] " a
  case $a in o|O|y|Y) return 0 ;; s|S) return 1 ;; *) echo "Arrêt demandé."; exit 0 ;; esac
}
title() { echo; echo "████████ $* ████████"; }
etcd_health() {
  local cp; cp=$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || { echo "  (etcd : état indisponible)"; return 0; }
  kubectl -n kube-system exec "$cp" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key endpoint health --cluster 2>&1 | awk '{print "  " $1, $3}' || true
}
cp_state() {
  kubectl -n kube-system get pods -l tier=control-plane -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready --sort-by=.metadata.name \
    || echo "(état du control plane indisponible : API ou proxy momentanément injoignable)"
  etcd_health
}
nodes_state() {
  kubectl get nodes -o custom-columns=NOEUD:.metadata.name,READY:.status.conditions[-1].status,KUBELET:.status.nodeInfo.kubeletVersion,CORDON:.spec.unschedulable,TAINTS:.spec.taints[*].key \
    || echo "(état des nœuds indisponible : API ou proxy momentanément injoignable)"
}

# Étapes déjà faites, lues dans l'API : on ne repose pas la question.
cp_at_target() {  # tous les kube-apiserver à la cible
  local imgs; imgs=$(kubectl -n kube-system get pods -l component=kube-apiserver -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null) || return 1
  [ -n "$imgs" ] && ! grep -qv ":$TARGET\$" <<<"$imgs"
}
kubelets_at_target() {  # kubelets des hôtes donnés à la cible
  local n
  for n in "$@"; do
    [ "$(kubectl get node "$n" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)" = "$TARGET" ] || return 1
  done
}

mapfile -t PRIMARY < <(hosts master_primary)
mapfile -t OTHERS < <(hosts 'masters:!master_primary')
[ ${#PRIMARY[@]} -eq 1 ] || { echo "Il faut exactement un hôte dans [master_primary]." >&2; exit 1; }

echo "Cluster : $(kubectl config current-context)   cible : $TARGET (dépôt $SERIES)"
echo "Masters : ${PRIMARY[0]} (apply) ${OTHERS[*]}"
[ -n "$LEGACY" ] && echo "Legacy  : $(hosts "$LEGACY" | tr '\n' ' ')"

# ── 0. contrôles ──────────────────────────────────────────────────────────────
title "0. Contrôles préalables"
nodes_state
etcd_health
FAIL=0
NOTREADY=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1"("$2")"}')
[ -z "$NOTREADY" ] || { echo "✗ nœuds non Ready / cordonnés : $NOTREADY"; FAIL=1; }
PRESSURE=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.taints[*].key}{"\n"}{end}' | grep -E 'pressure' | awk '{print $1}' || true)
[ -z "$PRESSURE" ] || { echo "✗ nœuds sous pression (disque/mémoire/PID) : $(echo $PRESSURE)"; FAIL=1; }
OLD=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.nodeInfo.kubeletVersion}{"\n"}{end}' \
  | awk -v m="$MINOR" '{split($2,v,"."); if (v[2] < m-1) print $1"("$2")"}')
[ -z "$OLD" ] || { echo "✗ kubelets trop anciens pour kubeadm $SERIES (min v1.$((MINOR - 1))) : $(echo $OLD)"; FAIL=1; }
if [ $FAIL -ne 0 ]; then echo; echo "Contrôles KO : corriger avant de monter de version."; exit 1; fi
echo "✓ contrôles OK"

read -rsp "Mot de passe sudo (become) : " BPW; echo
PWF=$(mktemp); chmod 600 "$PWF"; trap 'rm -f "$PWF"' EXIT
printf '%s\n' "$BPW" > "$PWF"; unset BPW
export BECOME_PASSWORD_FILE=$PWF

# ── 1. prepare ────────────────────────────────────────────────────────────────
title "1. Préparation des masters (kubeadm $TARGET, images, plan) — rien d'appliqué"
if cp_at_target; then
  echo "✓ déjà fait : tous les apiservers sont en $TARGET (étapes 1 et 2 sautées)"
elif ask "Lancer upgrade:kubeadm_prepare sur tous les masters ?"; then
  ./cluster upgrade:kubeadm_prepare "$INV" --become-password-file "$PWF" "${EV[@]}"
fi

# ── 2. control plane ──────────────────────────────────────────────────────────
title "2. Control plane, master par master"
for m in "${PRIMARY[0]}" "${OTHERS[@]}"; do
  cp_at_target && break
  echo; echo "── $m $([ "$m" = "${PRIMARY[0]}" ] && echo '(kubeadm upgrade apply)' || echo '(kubeadm upgrade node)')"
  if ask "Lancer upgrade:kubeadm_control_plane sur $m ?"; then
    ./cluster upgrade:kubeadm_control_plane "$INV" --become-password-file "$PWF" --limit "$m" "${EV[@]}"
    cp_state
  fi
done

# ── 3. / 4. kubelets ──────────────────────────────────────────────────────────
title "3. Kubelets des masters"
if kubelets_at_target "${PRIMARY[0]}" "${OTHERS[@]}"; then
  echo "✓ déjà fait : kubelets des masters en $TARGET"
elif ask "Lancer les kubelets des masters (un par un) ?"; then
  tools/rolling_nodes.sh upgrade:kubeadm_nodes_masters "$INV" masters "${EV[@]}"
fi
title "4. Kubelets des workers"
mapfile -t WORKERS < <(hosts workers)
if kubelets_at_target "${WORKERS[@]}"; then
  echo "✓ déjà fait : kubelets des workers en $TARGET"
elif ask "Lancer les kubelets des workers (un par un) ?"; then
  tools/rolling_nodes.sh upgrade:kubeadm_nodes_workers "$INV" workers "${EV[@]}"
fi

# ── 5. legacy (raw) ───────────────────────────────────────────────────────────
if [ -n "$LEGACY" ]; then
  title "5. Nœuds legacy ($LEGACY) : paquets via raw"
  # Le paquet kubelet de pkgs.k8s.io livre /etc/default/kubelet (KUBELET_EXTRA_ARGS= vide), et
  # EnvironmentFile= écrase Environment= du drop-in : un --root-dir passé via KUBELET_EXTRA_ARGS
  # dans 10-kubeadm.conf serait perdu à chaque mineure (racine kubelet retombée sur /var).
  # Donc : on relève le --root-dir AVANT, on garde le /etc/default/kubelet existant (confold) et
  # on le vide s'il redéfinit KUBELET_EXTRA_ARGS, puis on VÉRIFIE après restart (échec sinon).
  RAW='set -a; . /etc/environment; set +a;
ROOTDIR=$(tr "\0" "\n" </proc/$(pidof kubelet)/cmdline 2>/dev/null | grep -- "--root-dir" || true);
echo "root-dir avant : ${ROOTDIR:-défaut}";
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo "attente verrou dpkg"; sleep 5; done;
sed -i "s#/v[0-9.]*/deb/#/'"$SERIES"'/deb/#" /etc/apt/sources.list.d/kubernetes.list && apt-get update -qq &&
! apt-get install -s kubeadm='"$VERSION"'-1.1 kubelet='"$VERSION"'-1.1 kubectl='"$VERSION"'-1.1 | grep -q "^Remv" &&
apt-mark unhold kubeadm kubelet kubectl >/dev/null &&
DEBIAN_FRONTEND=noninteractive apt-get install -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold kubeadm='"$VERSION"'-1.1 kubelet='"$VERSION"'-1.1 kubectl='"$VERSION"'-1.1 >/tmp/kubelet-'"$VERSION"'.log 2>&1 &&
{ [ -z "$ROOTDIR" ] || ! grep -q "^KUBELET_EXTRA_ARGS=" /etc/default/kubelet 2>/dev/null || { : > /etc/default/kubelet; echo "/etc/default/kubelet vidé (préserve le --root-dir)"; }; } &&
apt-mark hold kubeadm kubelet kubectl >/dev/null &&
env -u http_proxy -u https_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY kubeadm upgrade node 2>&1 | tail -1 &&
systemctl daemon-reload && systemctl restart kubelet && sleep 15 &&
AFTER=$(tr "\0" "\n" </proc/$(pidof kubelet)/cmdline 2>/dev/null | grep -- "--root-dir" || true) &&
echo "kubelet: $(systemctl is-active kubelet) $(kubelet --version) | hold: $(apt-mark showhold | tr "\n" " ") | root-dir après : ${AFTER:-défaut}" &&
{ [ "$ROOTDIR" = "$AFTER" ] || { echo "ÉCHEC : --root-dir perdu (avant : $ROOTDIR, après : ${AFTER:-défaut})"; exit 1; }; }'
  for n in $(hosts "$LEGACY"); do
    state=$(kubectl get node "$n" -o 'jsonpath={.status.nodeInfo.kubeletVersion}|{.spec.unschedulable}')
    if [ "$state" = "$TARGET|" ]; then echo "déjà en $TARGET, sauté : $n"; continue; fi
    echo; echo "── $n ($state)"
    ask "Drainer puis monter $n ?" || continue
    until kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --timeout=180s; do
      echo "Drain de $n bloqué (voir ci-dessus : pods sans contrôleur, PDB…). Nœud cordonné."
      ask "Réessayer le drain ?" || { echo "$n laissé cordonné, sauté."; continue 2; }
    done
    "$ANSIBLE" "$n" -i "$INV" -b --become-password-file "$PWF" -m raw -a "$RAW"
    for _ in $(seq 1 30); do
      [ "$(kubectl get node "$n" -o 'jsonpath={.status.nodeInfo.kubeletVersion}|{.status.conditions[?(@.type=="Ready")].status}')" = "$TARGET|True" ] && break
      sleep 5
    done
    kubectl get node "$n" -o custom-columns=NOEUD:.metadata.name,READY:.status.conditions[-1].status,KUBELET:.status.nodeInfo.kubeletVersion
    if [ "$(kubectl get node "$n" -o 'jsonpath={.status.nodeInfo.kubeletVersion}')" = "$TARGET" ]; then
      kubectl uncordon "$n"
    else
      echo "✗ $n n'est pas revenu en $TARGET : laissé cordonné (voir journalctl -u kubelet sur le nœud)."
      ask "Continuer avec les nœuds suivants ?" || exit 1
    fi
  done
fi

# ── 6. état final ─────────────────────────────────────────────────────────────
title "6. État final"
nodes_state
cp_state
echo "Pods non sains :"
kubectl get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "  aucun"
