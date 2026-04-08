#!/usr/bin/env bash
# Synthetic monitoring probe — mide tiempos de respuesta como los vería un usuario externo
# y los escribe en InfluxDB para visualizarlos en Grafana.
set -euo pipefail

INFLUXDB_URL="${INFLUXDB_URL:-http://localhost:8086}"
INFLUXDB_DB="${INFLUXDB_DB:-k6}"
INTERVAL="${PROBE_INTERVAL:-10}"   # segundos entre cada probe

if [ -z "${BASE_URL:-}" ]; then
  MINIKUBE_IP=$(minikube ip)
  NODE_PORT=$(kubectl get svc math-api -o jsonpath='{.spec.ports[0].nodePort}')
  BASE_URL="http://$MINIKUBE_IP:$NODE_PORT"
fi

# Timestamp en nanosegundos para InfluxDB line protocol
now_ns() { python3 -c "import time; print(int(time.time() * 1e9))"; }

# Extrae un campo del JSON via python3 (disponible en macOS sin deps extras)
json_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1', $2))" 2>/dev/null || echo "$2"; }

write_influx() {
  curl -s -XPOST "${INFLUXDB_URL}/write?db=${INFLUXDB_DB}" \
    --data-binary "$1" > /dev/null || true
}

run_probe() {
  local ts
  ts=$(now_ns)

  # ── 1. Health check ───────────────────────────────────────────────────────
  local health_ms
  health_ms=$(curl -o /dev/null -s -w '%{time_total}' --max-time 5 "$BASE_URL/health" \
    | awk '{printf "%d", $1*1000}')

  # ── 2. Submit ─────────────────────────────────────────────────────────────
  local t0 submit_ms submit_body task_id
  t0=$(now_ns)
  submit_body=$(curl -s --max-time 5 -X POST "$BASE_URL/primes?limit=100000" 2>/dev/null || echo '{}')
  submit_ms=$(( ($(now_ns) - t0) / 1000000 ))
  task_id=$(echo "$submit_body" | json_get task_id "''")

  if [ -z "$task_id" ] || [ "$task_id" = "''" ]; then
    echo "[probe] $(date '+%H:%M:%S') submit falló — health=${health_ms}ms"
    write_influx "synthetic_probe health_ms=${health_ms},submit_ms=${submit_ms},total_ms=0,queue_wait_ms=0,success=0i ${ts}"
    return
  fi

  # ── 3. Poll hasta done ────────────────────────────────────────────────────
  local poll_start result status total_ms queue_wait_ms success
  poll_start=$(now_ns)
  status="pending"
  result='{}'

  for ((i=0; i<60; i++)); do
    result=$(curl -s --max-time 5 "$BASE_URL/primes/$task_id" 2>/dev/null || echo '{}')
    status=$(echo "$result" | json_get status "''")
    [ "$status" = "done" ] && break
    sleep 0.5
  done

  total_ms=$(( ($(now_ns) - poll_start + submit_ms * 1000000) / 1000000 ))
  queue_wait_ms=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d.get('queue_wait_s',0)*1000))" 2>/dev/null || echo "0")
  success=1
  [ "$status" != "done" ] && success=0

  echo "[probe] $(date '+%H:%M:%S') health=${health_ms}ms submit=${submit_ms}ms queue_wait=${queue_wait_ms}ms total=${total_ms}ms ok=${success}"
  write_influx "synthetic_probe health_ms=${health_ms},submit_ms=${submit_ms},total_ms=${total_ms},queue_wait_ms=${queue_wait_ms},success=${success}i ${ts}"
}

echo "Synthetic probe iniciado → $BASE_URL  (intervalo: ${INTERVAL}s, InfluxDB: ${INFLUXDB_URL}/${INFLUXDB_DB})"
while true; do
  run_probe &   # en background para que el sleep no se desfase si el probe tarda
  sleep "$INTERVAL"
done
