# Kubernetes HPA + KEDA Event-Driven Demo

Demostración de autoscaling en Kubernetes combinando HPA (Horizontal Pod Autoscaler) y KEDA (Kubernetes Event Driven Autoscaler) sobre una arquitectura event-driven con RabbitMQ y Redis.

El test de carga simula tráfico real mediante dos modelos estadísticos combinados:

- **Proceso de Poisson** — las llegadas de requests se modelan con `ramping-arrival-rate`, controlando la tasa λ (req/s) en lugar del número de usuarios. En un proceso de Poisson, los eventos son independientes entre sí y la tasa se mantiene constante dentro de cada intervalo, independientemente del tiempo de respuesta del servidor. Esto refleja cómo funciona el tráfico real en producción.

- **Distribución exponencial para el think time** — el tiempo de espera entre requests de un mismo usuario sigue una distribución exponencial (media 0.5s), que es la distribución continua de los intervalos en un proceso de Poisson. Esto evita el patrón artificial de un `sleep` fijo y hace que cada VU se comporte de forma independiente y aleatoria.

---

## Arquitectura

```
k6 ──POST /primes──▶ math-api ──▶ RabbitMQ (tasks queue)
                                          │
                                    worker (x N) ◀── KEDA ScaledObject
                                          │
k6 ──GET /primes/{id}──▶ math-api ◀──  Redis
```

**Flujo de un request:**
1. k6 envía `POST /primes?limit=N` → math-api publica un mensaje en la cola y devuelve `{task_id, status: "pending"}` con HTTP 202
2. Un worker consume el mensaje, ejecuta la Criba de Eratóstenes y guarda el resultado en Redis
3. k6 hace polling a `GET /primes/{task_id}` hasta obtener `{status: "done"}`

---

## Estructura del proyecto

```
.
├── app.py                  # API FastAPI: publica en cola y consulta resultados en Redis
├── worker.py               # Consumer RabbitMQ: calcula primos y guarda en Redis
├── Dockerfile              # Imagen compartida para math-api y worker
├── requirements.txt        # Dependencias Python
├── math-api.yaml           # Deployment + Service de math-api
├── math-api-hpa.yaml       # HPA para math-api (escala por CPU)
├── worker.yaml             # Deployment del worker
├── keda-scaledobject.yaml  # KEDA ScaledObject: escala workers por profundidad de cola
├── rabbitmq.yaml           # Deployment + Service + ConfigMap de RabbitMQ
├── redis.yaml              # Deployment + Service de Redis
├── nginx-app.yaml          # Deployment + Service de nginx (demo adicional)
├── nginx-hpa.yaml          # HPA para nginx
├── stress.js               # Script de carga k6 con patrón async request-reply
├── test.sh                 # Suite de tests funcionales de la API
└── monitoring/             # Stack de observabilidad local
    ├── docker-compose.yml      # InfluxDB + Prometheus + Grafana
    ├── prometheus.yml          # Configuración de scraping
    ├── kube-state-metrics.yaml # Métricas de deployments/pods para Prometheus
    ├── start.sh                # Levanta port-forwards + docker compose
    ├── stop.sh                 # Detiene el stack
    └── grafana/
        ├── provisioning/       # Datasources y dashboards pre-configurados
        └── dashboards/
            └── autoscale2.json # Dashboard principal
```

---

## Cómo funciona el autoscaling

### math-api — HPA por CPU

`math-api` es el API gateway: recibe requests y publica en la cola. Su carga es proporcional al tráfico entrante, por lo que escala bien por CPU.

Definido en `math-api-hpa.yaml`:

| Parámetro | Valor |
|---|---|
| Réplicas mínimas | 1 |
| Réplicas máximas | 10 |
| Umbral de escala | 70% de CPU promedio |
| Ventana de scale-down | 10 segundos |
| Política de scale-down | Máximo 50% de pods cada 15s |

### workers — KEDA por profundidad de cola

Los workers procesan los mensajes de la cola. KEDA observa directamente la profundidad de la cola `tasks` en RabbitMQ y escala los workers en consecuencia.

Definido en `keda-scaledobject.yaml`:

| Parámetro | Valor |
|---|---|
| Réplicas mínimas | 1 (siempre al menos un worker listo) |
| Réplicas máximas | 30 |
| Trigger | RabbitMQ queue length |
| Umbral | 1 worker adicional por cada 10 mensajes en cola |
| Polling interval | 5 segundos |
| Cooldown | 30 segundos antes de escalar al mínimo |
| Ventana de scale-down | 30 segundos (HPA behavior) |
| Política de scale-down | Máximo 50% de pods cada 15s |

La ventaja de KEDA sobre HPA por CPU es que reacciona **antes** de que el CPU suba: en cuanto hay mensajes en la cola, ya escala. El mínimo de 1 réplica garantiza que siempre haya un worker listo para tomar el primer mensaje sin cold-start.

### El script de carga: stress.js

`stress.js` implementa el patrón **async request-reply**:

1. `POST /primes?limit=N` → obtiene `task_id`
2. Polling `GET /primes/{task_id}` cada 0.5s hasta recibir `status: done` (máximo 30 intentos)

#### Modelo de llegadas: `ramping-arrival-rate`

```
  req/s
  200 |          ████████
  100 |      ████        ████
   20 |  ████                ████
    5 |█                        ████
    0 |──────────────────────────────── tiempo
       30s   2m    2m    30s
```

| Etapa | Duración | req/s | Descripción |
|---|---|---|---|
| Ramp up | 30s | 5 → 20 | Arranque gradual |
| Carga media | 2m | 20 → 100 | Trigger de primeros scale-outs |
| Carga máxima | 2m | 100 → 200 | Presión máxima |
| Ramp down | 30s | 200 → 0 | Bajada para observar scale-in |

#### Variabilidad realista

| Límite de primos | Probabilidad | Carga CPU |
|---|---|---|
| 100,000 | 40% | Baja |
| 250,000 | 30% | Media-baja |
| 500,000 | 20% | Media |
| 750,000 | 7% | Alta |
| 1,000,000 | 3% | Muy alta |

---

## Requisitos previos

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://www.docker.com/)
- [k6](https://k6.io/docs/get-started/installation/) (v0.49+ para web dashboard integrado)
- [KEDA](https://keda.sh/docs/latest/deploy/)
- Docker Compose (para el stack de monitoreo)

---

## Despliegue

### 1. Iniciar minikube con metrics-server

```bash
minikube start
minikube addons enable metrics-server
```

### 2. Instalar KEDA

```bash
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.16.0/keda-2.16.0.yaml
```

Verificar que KEDA esté listo:

```bash
kubectl get pods -n keda
```

### 3. Construir la imagen dentro de minikube

> La imagen debe construirse en el contexto Docker de minikube porque `imagePullPolicy: Never` impide que se descargue desde un registry externo. La misma imagen se usa para math-api y para el worker (distinto comando de arranque).

```bash
eval $(minikube docker-env)
docker build -t math-api:latest .
```

### 4. Desplegar la infraestructura

```bash
kubectl apply -f rabbitmq.yaml
kubectl apply -f redis.yaml
```

Esperar a que estén listos:

```bash
kubectl wait --for=condition=ready pod -l app=rabbitmq --timeout=60s
kubectl wait --for=condition=ready pod -l app=redis --timeout=30s
```

### 5. Desplegar math-api y worker

```bash
kubectl apply -f math-api.yaml
kubectl apply -f math-api-hpa.yaml
kubectl apply -f worker.yaml
kubectl apply -f keda-scaledobject.yaml
```

### 6. Desplegar kube-state-metrics (necesario para monitoreo)

```bash
kubectl apply -f monitoring/kube-state-metrics.yaml
kubectl wait --for=condition=ready pod -l app=kube-state-metrics -n monitoring --timeout=60s
```

### 7. (Opcional) Desplegar nginx

```bash
kubectl apply -f nginx-app.yaml
kubectl apply -f nginx-hpa.yaml
```

### 8. Verificar el estado

```bash
kubectl get pods
kubectl get hpa
kubectl get scaledobject
```

---

## Monitoreo con Grafana

El stack de monitoreo incluye:

- **InfluxDB** — almacena las métricas de k6 (requests, latencia, VUs)
- **Prometheus** — scrapea RabbitMQ (puerto 15692) y kube-state-metrics
- **Grafana** — dashboard pre-configurado con todos los paneles

### Iniciar el stack

```bash
cd monitoring && ./start.sh
```

El script levanta los port-forwards necesarios y el stack Docker. Luego abre:

| Servicio | URL |
|---|---|
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

### Synthetic probe

El stack incluye un proceso que corre en background y simula un usuario externo cada N segundos, midiendo los tiempos reales de extremo a extremo y escribiéndolos en InfluxDB. Se inicia automáticamente con `start.sh`.

```bash
# Intervalo por defecto: 1s. Se puede cambiar con la variable de entorno:
PROBE_INTERVAL=5 ./monitoring/start.sh

# O correrlo independientemente:
PROBE_INTERVAL=10 BASE_URL=http://192.168.49.2:31234 ./monitoring/synthetic_probe.sh
```

Salida de consola:
```
[probe] 18:42:01 health=12ms submit=45ms queue_wait=320ms total=412ms ok=1
[probe] 18:42:11 health=8ms  submit=31ms queue_wait=5820ms total=5901ms ok=1
```

### Dashboard: Autoscale2 – Test Overview

El dashboard incluye los siguientes paneles:

| Panel | Fuente | Métricas |
|---|---|---|
| Requests / Failures / Peak RPS / P95 | InfluxDB (k6) | Totales del test |
| Performance Overview | InfluxDB (k6) | VUs, request rate, response time, failure rate |
| Synthetic Probe – Experiencia del usuario externo | InfluxDB (probe) | Health, submit, queue wait y total end-to-end |
| Queue Wait Time | InfluxDB (k6) | p50 / p95 / p99 del tiempo en cola |
| Queue Depth & Worker Autoscaling | Prometheus | Mensajes listos, unacked y worker pods |
| RabbitMQ – Salud del broker | Prometheus | Conexiones AMQP y channels |
| RabbitMQ – Memoria y alarmas | Prometheus | Memoria RSS y alarma de high watermark |

### Detener el stack

```bash
cd monitoring && ./stop.sh
```

---

## Ejecutar el test de carga

### 1. Obtener la URL del Service

> Es importante usar esta URL y no `kubectl port-forward`, ya que port-forward fija el tráfico a un único pod y no permite observar el balanceo real entre réplicas.

```bash
minikube service math-api --url
# Ejemplo de salida: http://192.168.49.2:31234
```

### 2. Ejecutar k6

Con métricas en Grafana:

```bash
k6 run -e BASE_URL=http://192.168.49.2:31234 \
  --out influxdb=http://localhost:8086/k6 \
  stress.js
```

Sin Grafana (dashboard integrado de k6):

```bash
k6 run -e BASE_URL=http://192.168.49.2:31234 \
  --out web-dashboard \
  stress.js
# Abrir http://localhost:5665
```

### 3. Observar el comportamiento en tiempo real

```bash
# Pods, CPU y memoria
watch kubectl top pods

# Estado del HPA (math-api)
watch kubectl get hpa math-api-hpa

# Estado del ScaledObject (workers)
watch kubectl get scaledobject worker-scaledobject

# Cola de RabbitMQ
kubectl exec -it deploy/rabbitmq -- rabbitmqctl list_queues name messages consumers
```

---

## Comportamiento esperado

1. Al iniciar el test, math-api publica mensajes en la cola.
2. KEDA detecta mensajes en la cola y escala los workers (mínimo 1 siempre activo).
3. Los workers procesan los mensajes y guardan resultados en Redis.
4. k6 obtiene los resultados via polling al endpoint `GET /primes/{task_id}`.
5. Si la cola crece más rápido de lo que los workers procesan, KEDA agrega más workers (hasta 30).
6. Al terminar el test, la cola se vacía y KEDA escala los workers de vuelta a 1.
7. math-api también escala down gradualmente por el HPA (máximo 50% de pods cada 15s).

En Grafana se puede observar la correlación directa entre la profundidad de la cola (naranja) y el número de worker pods (azul), que es el comportamiento central que demuestra KEDA.

---

## Notas de implementación

### Resiliencia de conexiones

Tanto `math-api` como `worker` implementan lógica de reconexión ante fallos de RabbitMQ:

- **math-api**: reintentos con backoff en el startup (10 intentos × 3s) mediante `aio_pika.connect_robust`
- **worker**: loop infinito de reconexión que sobrevive caídas temporales del broker

### RabbitMQ

El plugin `rabbitmq_prometheus` está habilitado via ConfigMap junto con `rabbitmq.conf`, que configura `vm_memory_high_watermark.relative = 0.8` (el broker activa la alarma de memoria al 80% del límite del contenedor, en lugar del 40% por defecto). La readiness probe usa TCP socket en lugar de `rabbitmq-diagnostics ping` para evitar falsos negativos bajo carga.

### Concurrencia de publishes en math-api

Un semáforo (`asyncio.Semaphore`) limita a 50 el número de publishes concurrentes hacia RabbitMQ. Esto evita que bajo carga extrema se acumulen coroutines bloqueadas que degraden el event loop e impidan responder rápido a endpoints como `/health`.

### Time-to-done: queue wait vs processing

Cada mensaje incluye el timestamp de publicación (`published_at`). El worker calcula `queue_wait_s` al consumirlo y lo persiste en Redis junto al resultado. `stress.js` lee este campo y lo emite como métrica `queue_wait_ms` hacia InfluxDB, visible en Grafana con percentiles p50/p95/p99.

### Alta cardinalidad en métricas k6

Las URLs de polling (`GET /primes/{task_id}`) usan el tag `name: 'GET /primes/:id'` para agrupar todas las requests bajo una sola serie en InfluxDB, evitando la explosión de cardinalidad que ocurre cuando cada `task_id` único genera una serie diferente.
