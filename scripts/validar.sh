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
# Espera até existirem exatamente N pods, todos prontos (pods em Terminating contam).
esperar_pods() {
  for _ in $(seq 1 90); do
    total=$(kubectl -n "$NS" get pods -l app=app-portal --no-headers 2>/dev/null | wc -l)
    [ "$total" = "$1" ] && [ "$(prontos)" = "$1" ] && return 0
    sleep 2
  done
  return 1
}
versao() { curl -fsS "$URL/api/pod" | sed -E 's/.*"version":"([^"]+)".*/\1/'; }

echo "1. Aplicando os manifestos"
kubectl apply -k k8s >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
esperar_pods 3 && ok "Deployment com 3 réplicas prontas" || falha "réplicas prontas: $(prontos)"

echo "2. Acesso pelo NodePort ($URL)"
for _ in $(seq 1 30); do curl -fsS "$URL/healthz" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "$URL/healthz" | grep -q ok && ok "/healthz responde" || falha "/healthz"
curl -fsS "$URL/" | grep -q "Portal de aplicações da TechFleet" && ok "página do portal servida pelo ConfigMap" || falha "página"
distintos=$(for _ in $(seq 1 30); do curl -fsS "$URL/api/pod"; echo; done | sed -E 's/.*"pod":"([^"]+)".*/\1/' | sort -u | wc -l)
[ "$distintos" -ge 2 ] && ok "Service distribuiu 30 requisições entre $distintos pods" || falha "só $distintos pod respondeu"

echo "3. Escalabilidade: 3 -> 5 réplicas"
kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=5 >/dev/null
esperar_pods 5
[ "$(prontos)" = "5" ] && ok "5 réplicas prontas" || falha "réplicas prontas: $(prontos)"
kubectl -n "$NS" scale deploy/"$DEPLOY" --replicas=3 >/dev/null
esperar_pods 3 && ok "de volta a 3 réplicas" || falha "não voltou a 3 réplicas"

echo "4. Resiliência: excluindo um pod"
alvo=$(kubectl -n "$NS" get pods -l app=app-portal -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" delete pod "$alvo" >/dev/null
esperar_pods 3 || falha "o Deployment não recriou o pod"
kubectl -n "$NS" get pods -l app=app-portal -o name | grep -q "$alvo" && falha "o pod $alvo ainda existe"
ok "$alvo excluído e substituído; 3 pods prontos de novo"

echo "5. Rolling update: v1.0.0 -> v1.1.0 e rollback"
# Enquanto o rollout acontece, um laço faz requisições e conta as falhas.
log=$(mktemp)
( while :; do curl -fsS -m 2 "$URL/api/pod" >/dev/null 2>&1 && echo ok >>"$log" || echo erro >>"$log"; sleep 0.2; done ) &
laco=$!
kubectl -n "$NS" set env deploy/"$DEPLOY" APP_VERSION=1.1.0 >/dev/null
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
esperar_pods 3
kill "$laco"; wait "$laco" 2>/dev/null || true
[ "$(versao)" = "1.1.0" ] && ok "todas as réplicas atualizadas para v1.1.0" || falha "versão: $(versao)"
erros=$(grep -c erro "$log" || true)
echo "      durante o rollout: $(grep -c ok "$log") respostas ok, $erros falhas"
rm -f "$log"
[ "$erros" = "0" ] && ok "nenhuma requisição perdida durante o rollout" || falha "$erros requisições falharam no rollout"
kubectl -n "$NS" rollout undo deploy/"$DEPLOY" >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=180s >/dev/null
esperar_pods 3
[ "$(versao)" = "1.0.0" ] && ok "rollback para v1.0.0" || falha "versão após rollback: $(versao)"

echo "Tudo certo."
