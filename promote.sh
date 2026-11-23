#!/usr/bin/env bash
# Usage: ./promote.sh <env-source> <env-cible>
set -euo pipefail
FROM=${1:?usage: ./promote.sh dev staging}
TO=${2:?usage: ./promote.sh dev staging}
cd "$(dirname "$0")"

# Garde-fou : on ne promeut que depuis un environnement sain
HEALTH=$(kubectl get application portfolio-$FROM -n argocd -o jsonpath='{.status.health.status}')
[ "$HEALTH" = "Healthy" ] || { echo "ERREUR: portfolio-$FROM n'est pas Healthy ($HEALTH)"; exit 1; }

IMAGES=("192.168.159.129/devsecops-portfolio/api" "192.168.159.129/devsecops-portfolio/frontend")
for img in "${IMAGES[@]}"; do
  d=$(awk -v n="name: $img" 'index($0,n){f=1} f&&/digest:/{print $2; exit}' overlays/$FROM/kustomization.yaml)
  [ -n "$d" ] || { echo "ERREUR: digest introuvable pour $img dans $FROM"; exit 1; }
  sed -i -E "\#name: $img\$#,\#(newTag|digest):# s#(newTag|digest): .*#digest: $d#" overlays/$TO/kustomization.yaml
  echo "$FROM -> $TO : $img @ $d"
done

git add overlays/$TO/kustomization.yaml
git commit -m "promote: $FROM -> $TO (meme digest, sans rebuild)"
git push
kubectl annotate application -n argocd portfolio-$TO argocd.argoproj.io/refresh=hard --overwrite
