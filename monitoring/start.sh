#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PF_PIDS=()

cleanup() {
  echo ""
  echo "Deteniendo port-forwards..."
  for pid in "${PF_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  echo "Listo. El stack de Docker sigue corriendo. Para detenerlo: ./stop.sh"
}
trap cleanup EXIT INT TERM

# ── Port-forwards ─────────────────────────────────────────────────────────────
echo "Iniciando port-forwards..."

kubectl port-forward svc/rabbitmq 15692:15692 > /tmp/pf-rabbit-prom.log 2>&1 &
PF_PIDS+=($!)
echo "  RabbitMQ Prometheus → localhost:15692"

kubectl port-forward svc/kube-state-metrics 18080:8080 -n monitoring > /tmp/pf-ksm.log 2>&1 &
PF_PIDS+=($!)
echo "  kube-state-metrics  → localhost:18080"

# Esperar a que los port-forwards estén listos
sleep 2

# ── Docker Compose ────────────────────────────────────────────────────────────
echo ""
echo "Levantando stack de monitoreo..."
cd "$SCRIPT_DIR"
docker compose up -d

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grafana:    http://localhost:3000"
echo "  Prometheus: http://localhost:9090"
echo "  InfluxDB:   http://localhost:8086"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Para correr el test:"
echo "  k6 run --out influxdb=http://localhost:8086/k6 ../stress.js"
echo ""
echo "Ctrl+C para detener los port-forwards."
echo ""

# Mantener vivo para que el trap funcione
wait "${PF_PIDS[@]}"
