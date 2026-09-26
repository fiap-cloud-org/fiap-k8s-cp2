#!/usr/bin/env bash
# Valida a entrega no cluster atual (kubectl já apontando para ele):
# deploy, NodePort, balanceamento, escala 3 -> 5, autorrecuperação e rolling update.
# Uso: ./scripts/validar.sh [URL]   (padrão: http://localhost:30080)
set -euo pipefail

URL="${1:-http://localhost:30080}"
NS=producao
DEPLOY=app-portal
ok() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
falha() { printf '  \033[31mFALHOU\033[0m  %s\n' "$*"; exit 1; }
prontos() { kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}'; }
versao() { curl -fsS "$URL/api/pod" | sed -E 's/.*"version":"([^"]+)".*/\1/'; }

echo "1. Aplicando os manifestos"
kubectl apply -k k8s >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
[ "$(prontos)" = "3" ] && ok "Deployment com 3 réplicas prontas" || falha "réplicas prontas: $(prontos)"

echo "2. Acesso pelo NodePort ($URL)"
for _ in $(seq 1 30); do curl -fsS "$URL/healthz" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "$URL/healthz" | grep -q ok && ok "/healthz responde" || falha "/healthz"
curl -fsS "$URL/" | grep -q "Portal de aplicações da TechFleet" && ok "página do portal servida pelo ConfigMap" || falha "página"
distintos=$(for _ in $(seq 1 30); do curl -fsS "$URL/api/pod"; echo; done | sed -E 's/.*"pod":"([^"]+)".*/\1/' | sort -u | wc -l)
[ "$distintos" -ge 2 ] && ok "Service distribuiu 30 requisições entre $distintos pods" || falha "só $distintos pod respondeu"

echo "3. Escalabilidade: 3 -> 5 réplicas"
kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=5 >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=120s >/dev/null
[ "$(prontos)" = "5" ] && ok "5 réplicas prontas" || falha "réplicas prontas: $(prontos)"
kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=3 >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=120s >/dev/null
ok "de volta a 3 réplicas"

echo "4. Resiliência: excluindo um pod"
alvo=$(kubectl -n "$NS" get pods -l app=app-portal -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" delete pod "$alvo" --wait=false >/dev/null
sleep 3
kubectl -n "$NS" wait --for=condition=Ready pod -l app=app-portal --timeout=120s >/dev/null
kubectl -n "$NS" get pods -l app=app-portal -o name | grep -q "$alvo" && falha "o pod $alvo ainda existe"
[ "$(kubectl -n "$NS" get pods -l app=app-portal --no-headers | wc -l)" = "3" ] && ok "$alvo excluído e substituído; 3 pods de novo" || falha "quantidade de pods"

echo "5. Rolling update: v1.0.0 -> v1.1.0 e rollback"
kubectl -n "$NS" set env deploy/"$DEPLOY" APP_VERSION=1.1.0 >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
sleep 2
[ "$(versao)" = "1.1.0" ] && ok "todas as réplicas atualizadas para v1.1.0 sem derrubar o Service" || falha "versão: $(versao)"
kubectl -n "$NS" rollout undo deploy/"$DEPLOY" >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
sleep 2
[ "$(versao)" = "1.0.0" ] && ok "rollback para v1.0.0" || falha "versão após rollback: $(versao)"

echo "Tudo certo."
