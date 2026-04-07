#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Deteniendo stack de monitoreo..."
cd "$SCRIPT_DIR"
docker compose down

echo "Limpiando port-forwards residuales..."
pkill -f "kubectl port-forward svc/rabbitmq 15692" 2>/dev/null || true
pkill -f "kubectl port-forward svc/kube-state-metrics 18080" 2>/dev/null || true

echo "Listo."
