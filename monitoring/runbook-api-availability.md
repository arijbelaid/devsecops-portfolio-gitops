# Runbook : ApiAvailabilitySLOViolated

## Alerte

- **Nom** : `ApiAvailabilitySLOViolated` (sévérité `critical`)
- **Condition** : SLI de disponibilité de `/api/contact` sur 1 h inférieur à 99 % pendant 1 minute
- **SLO** : disponibilité ≥ 99 % (réponses non 5xx / requêtes totales)
- **Impact** : les visiteurs ne peuvent pas envoyer le formulaire de contact (réponse 500). Le reste du site peut rester accessible.
- **Où la voir** : Prometheus http://192.168.159.129:30090/alerts, Grafana http://192.168.159.129:30300

## 1. Confirmer l'incident

```bash
PROM_IP=$(kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.clusterIP}')
curl -s -G http://$PROM_IP:9090/api/v1/query --data-urlencode 'query=100 * sum(increase(http_requests_total{route="/api/contact",status!~"5.."}[1h])) / sum(increase(http_requests_total{route="/api/contact"}[1h]))'
```

Les 4xx (400 validation, 429 limiteur de débit) sont des erreurs du client : elles ne comptent pas dans l'indisponibilité.

## 2. Diagnostiquer (dans cet ordre)

**2.1 État des pods**

```bash
kubectl get pods -n devsecops-dev
```

Chercher un pod `api` ou `postgres` qui n'est pas en `Running`, des redémarrages, ou `ImagePullBackOff`.

**2.2 Logs d'erreur de l'API**

```bash
kubectl logs -n devsecops-dev deploy/api-deployment --tail=50 | grep -i "erreur"
```

Dans Grafana (Explore, Loki) : `{namespace="devsecops-dev", app="api"} |= "Erreur interceptée"`.

**2.3 Trace de la requête en erreur**

Copier le `correlationId` (`[cid=...]`) d'une ligne d'erreur, puis ouvrir Grafana, Explore, Tempo, Trace ID. Le span en rouge (`postgresql INSERT contact`, par exemple) indique le maillon en cause.

**2.4 Base de données**

```bash
DBURL=$(kubectl exec -n devsecops-dev deploy/api-deployment -- printenv DATABASE_URL)
DBPASS=$(echo "$DBURL" | sed 's#.*://[^:]*:\([^@]*\)@.*#\1#')
kubectl exec -n devsecops-dev deploy/postgres -- env PGPASSWORD="$DBPASS" psql -h 127.0.0.1 -U portfolio -d portfolio -c "\dt"
```

La table `contacts` doit être présente.

**2.5 Nœud et disque**

```bash
df -h / | tail -1
kubectl describe node | grep -E "Taints|DiskPressure"
```

## 3. Actions correctives

| Symptôme | Cause probable | Action |
|---|---|---|
| `table public.contacts does not exist` | Migration non appliquée ou Postgres redémarré (pas de volume persistant) | Relancer la migration (voir 3.1) |
| Table `contacts_off` présente | Table renommée | `ALTER TABLE contacts_off RENAME TO contacts;` via `psql` (2.4) |
| Pod `postgres` absent ou en erreur | Pod arrêté ou évincé | `kubectl rollout restart deploy/postgres -n devsecops-dev`, puis relancer la migration (3.1) |
| `ImagePullBackOff` | Harbor arrêté | `cd ~/cv-onepage/harbor && docker compose up -d`, puis `kubectl rollout restart deploy/api-deployment -n devsecops-dev` |
| `DiskPressure True`, pods `Evicted` | Disque presque plein | Libérer de l'espace (3.2) |
| Erreurs `webhook ... kyverno ... no endpoints` | Kyverno indisponible | `kubectl get pods -n kyverno` ; résoudre d'abord la cause (souvent le disque) |
| Cause inconnue après le diagnostic | Mauvais déploiement | Annuler le dernier commit du dépôt GitOps (`git revert`, `git push`), ArgoCD resynchronise |

**3.1 Relancer la migration**

```bash
cd ~/cv-onepage/devsecops-portfolio-gitops
kubectl delete job db-migrate -n devsecops-dev --ignore-not-found
kubectl kustomize overlays/dev | kubectl apply -f -
kubectl logs -n devsecops-dev job/db-migrate --tail=5
```

**3.2 Libérer le disque**

```bash
docker builder prune -af
docker image prune -f
sudo journalctl --vacuum-size=200M
df -h / | tail -1
```

Ne jamais utiliser `docker system prune --volumes` : cela peut supprimer les données de Harbor.

## 4. Vérifier la résolution

```bash
API_IP=$(kubectl get pod -n devsecops-dev -l app=api -o jsonpath='{.items[0].status.podIP}')
curl -s -o /dev/null -w "contact: %{http_code}\n" -X POST http://$API_IP:5000/api/contact \
  -H "Content-Type: application/json" -d '{"nom":"Verification","email":"test@example.com","message":"Retour a la normale"}'
```

Attendu : `200`. Le limiteur autorise 5 requêtes par 15 minutes ; un `rollout restart` de l'API le remet à zéro. L'alerte repasse à `Inactive` quand les erreurs sortent de la fenêtre de 1 h.

## 5. Escalade et suivi

- Si l'incident n'est pas résolu en 30 minutes, escalader au responsable du projet.
- Après l'incident, noter dans le rapport : heures de début et de fin, cause, `correlationId` d'une requête en erreur, action réalisée, SLI atteint.
