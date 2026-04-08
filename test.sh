#!/usr/bin/env bash
set -euo pipefail

if [ -z "${BASE_URL:-}" ]; then
  MINIKUBE_IP=$(minikube ip)
  NODE_PORT=$(kubectl get svc math-api -o jsonpath='{.spec.ports[0].nodePort}')
  BASE_URL="http://$MINIKUBE_IP:$NODE_PORT"
fi
POLL_INTERVAL=2
POLL_MAX=60   # bajo stress las tareas pueden quedar hasta ~30s en cola
PASS=0
FAIL=0

TEST_START=$SECONDS

green() { echo -e "\033[32m✔ $*\033[0m"; }
red()   { echo -e "\033[31m✘ $*\033[0m"; }
gray()  { echo -e "\033[90m  $*\033[0m"; }

pass() { green "$1"; ((++PASS)); }
fail() { red   "$1"; ((++FAIL)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label (got: $actual)"
  else
    fail "$label (esperado: $expected, got: $actual)"
  fi
}

echo ""
echo "Base URL: $BASE_URL"
echo "────────────────────────────────────"

# ── 1. Health check ──────────────────────────────────────────────────────────
t0=$SECONDS
STATUS=$(curl -s "$BASE_URL/health" | jq -r '.status')
assert_eq "GET /health devuelve status ok" "ok" "$STATUS"
gray "↳ health check: $((SECONDS - t0))s"

# ── 2. POST devuelve 202 ─────────────────────────────────────────────────────
t0=$SECONDS
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/primes?limit=100000")
assert_eq "POST /primes devuelve HTTP 202" "202" "$HTTP_CODE"
gray "↳ submit: $((SECONDS - t0))s"

# ── 3. POST devuelve task_id ─────────────────────────────────────────────────
t0=$SECONDS
TASK_ID=$(curl -s -X POST "$BASE_URL/primes?limit=100000" | jq -r '.task_id')
if [[ "$TASK_ID" =~ ^[0-9a-f-]{36}$ ]]; then
  pass "POST /primes devuelve task_id válido (UUID)"
else
  fail "POST /primes no devolvió un UUID válido (got: $TASK_ID)"
fi
gray "↳ submit: $((SECONDS - t0))s"

# ── 4. GET task pendiente devuelve pending o done ────────────────────────────
t0=$SECONDS
INITIAL_STATUS=$(curl -s "$BASE_URL/primes/$TASK_ID" | jq -r '.status')
if [[ "$INITIAL_STATUS" = "pending" || "$INITIAL_STATUS" = "done" ]]; then
  pass "GET /primes/{task_id} devuelve status válido (got: $INITIAL_STATUS)"
else
  fail "GET /primes/{task_id} devolvió status inesperado (got: $INITIAL_STATUS)"
fi
gray "↳ first poll: $((SECONDS - t0))s"

# ── 5. Polling hasta done ─────────────────────────────────────────────────────
POLL_START=$SECONDS
RESULT_STATUS="pending"
for ((i=1; i<=POLL_MAX; i++)); do
  RESULT_STATUS=$(curl -s "$BASE_URL/primes/$TASK_ID" | jq -r '.status')
  [ "$RESULT_STATUS" = "done" ] && break
  sleep $POLL_INTERVAL
done
POLL_ELAPSED=$((SECONDS - POLL_START))
assert_eq "Tarea completada en $((POLL_MAX * POLL_INTERVAL))s" "done" "$RESULT_STATUS"
gray "↳ tiempo hasta done: ${POLL_ELAPSED}s"

# ── 6. Resultado contiene campos esperados ───────────────────────────────────
RESULT=$(curl -s "$BASE_URL/primes/$TASK_ID")
COUNT=$(echo "$RESULT" | jq -r '.count')
LARGEST=$(echo "$RESULT" | jq -r '.largest_prime')
QUEUE_WAIT=$(echo "$RESULT" | jq -r '.queue_wait_s // "n/a"')
PROC_TIME=$(echo "$RESULT" | jq -r '.elapsed_s // "n/a"')

if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
  pass "Resultado tiene count > 0 (got: $COUNT)"
else
  fail "Resultado no tiene count válido (got: $COUNT)"
fi

if [[ "$LARGEST" =~ ^[0-9]+$ ]] && [ "$LARGEST" -gt 0 ]; then
  pass "Resultado tiene largest_prime > 0 (got: $LARGEST)"
else
  fail "Resultado no tiene largest_prime válido (got: $LARGEST)"
fi

gray "↳ tiempo en cola: ${QUEUE_WAIT}s  |  procesamiento: ${PROC_TIME}s"

# ── 7. Task inexistente devuelve 404 ─────────────────────────────────────────
#HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/primes/00000000-0000-0000-0000-000000000000")
#assert_eq "GET /primes/id-inexistente devuelve HTTP 404" "404" "$HTTP_CODE"

# ── 8. Validación: limit fuera de rango devuelve 422 ────────────────────────
#HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/primes?limit=1")
#assert_eq "POST /primes?limit=1 devuelve HTTP 422" "422" "$HTTP_CODE"

#HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/primes?limit=9999999")
#assert_eq "POST /primes?limit=9999999 devuelve HTTP 422" "422" "$HTTP_CODE"

# ── Resumen ──────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$((SECONDS - TEST_START))
echo "────────────────────────────────────"
echo "Resultado: $PASS pasaron, $FAIL fallaron"
printf "Tiempo total: %dm%02ds\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
echo ""
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
