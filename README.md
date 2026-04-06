# Kubernetes HPA Demo

Demostración de Horizontal Pod Autoscaler (HPA) en Kubernetes usando dos aplicaciones: una API REST con carga CPU intensiva y un servidor nginx.

El test de carga simula tráfico real mediante dos modelos estadísticos combinados:

- **Proceso de Poisson** — las llegadas de requests se modelan con `ramping-arrival-rate`, controlando la tasa λ (req/s) en lugar del número de usuarios. En un proceso de Poisson, los eventos son independientes entre sí y la tasa se mantiene constante dentro de cada intervalo, independientemente del tiempo de respuesta del servidor. Esto refleja cómo funciona el tráfico real en producción.

- **Distribución exponencial para el think time** — el tiempo de espera entre requests de un mismo usuario sigue una distribución exponencial (media 0.5s), que es la distribución continua de los intervalos en un proceso de Poisson. Esto evita el patrón artificial de un `sleep` fijo y hace que cada VU se comporte de forma independiente y aleatoria.

## Estructura del proyecto

```
.
├── app.py              # API FastAPI con endpoint /primes (CPU intensivo)
├── Dockerfile          # Imagen Docker para math-api
├── requirements.txt    # Dependencias Python
├── math-api.yaml       # Deployment + Service de math-api
├── math-api-hpa.yaml   # HPA para math-api (escala por CPU)
├── nginx-app.yaml      # Deployment + Service de nginx
├── nginx-hpa.yaml      # HPA para nginx (escala por CPU)
└── stress.js           # Script de carga k6
```

---

## Cómo funciona el test

### La aplicación: math-api

`app.py` expone un endpoint `GET /primes?limit=N` que calcula todos los números primos hasta `N` usando la **Criba de Eratóstenes**. Con el valor por defecto (`limit=500000`) cada request consume CPU de forma significativa, lo que permite observar el comportamiento del HPA bajo carga real.

### El HPA de math-api

Definido en `math-api-hpa.yaml`:

| Parámetro | Valor |
|---|---|
| Réplicas mínimas | 1 |
| Réplicas máximas | 10 |
| Umbral de escala | 30% de CPU promedio |
| Ventana de scale-down | 10 segundos |
| Política de scale-down | Máximo 50% de pods cada 15s |

Cuando el CPU promedio entre todos los pods supera el 30% del `request` configurado (250m), el HPA crea nuevos pods. Cuando baja, los reduce gradualmente para evitar cortes si el tráfico rebota.

### El script de carga: stress.js

`stress.js` es un test k6 que simula tráfico real usando un **modelo de Poisson**, que es como se comporta el tráfico en sistemas reales: las llegadas son aleatorias e independientes entre sí.

#### Modelo de llegadas: `ramping-arrival-rate`

En vez de controlar el número de usuarios (VUs), el test controla la **tasa de llegadas por segundo (λ)**. Esto es lo que diferencia un proceso de Poisson de una simulación de carga fija: aunque el servidor tarde más en responder, la tasa de requests se mantiene constante.

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
| Carga máxima | 2m | 100 → 200 | Presión máxima sobre los pods |
| Ramp down | 30s | 200 → 0 | Bajada para observar scale-in |

#### Variabilidad realista

Cada request usa un `limit` aleatorio con distribución de pesos, simulando que distintos usuarios generan distinta carga de CPU:

| Límite de primos | Probabilidad | Carga CPU |
|---|---|---|
| 100,000 | 40% | Baja |
| 250,000 | 30% | Media-baja |
| 500,000 | 20% | Media |
| 750,000 | 7% | Alta |
| 1,000,000 | 3% | Muy alta |

#### Think time exponencial

Entre requests, cada VU espera un tiempo aleatorio con **distribución exponencial** (media 0.5s), evitando el patrón artificial de un sleep fijo. Este tiempo no afecta la tasa de llegadas, que es controlada externamente por `ramping-arrival-rate`.

Cada VU abre una conexión nueva por request (`noConnectionReuse: true`), garantizando que kube-proxy distribuya el tráfico entre todos los pods.

---

## Requisitos previos

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://www.docker.com/)
- [k6](https://k6.io/docs/get-started/installation/)
- metrics-server habilitado en minikube

---

## Despliegue

### 1. Iniciar minikube con metrics-server

```bash
minikube start
minikube addons enable metrics-server
```

### 2. Construir la imagen dentro de minikube

> La imagen debe construirse en el contexto Docker de minikube porque `imagePullPolicy: Never` impide que se descargue desde un registry externo.

```bash
eval $(minikube docker-env)
docker build -t math-api:latest .
```

### 3. Desplegar math-api

```bash
kubectl apply -f math-api.yaml
kubectl apply -f math-api-hpa.yaml
```

### 4. (Opcional) Desplegar nginx

```bash
kubectl apply -f nginx-app.yaml
kubectl apply -f nginx-hpa.yaml
```

### 5. Verificar que los pods están corriendo

```bash
kubectl get pods
kubectl get hpa
```

---

## Ejecutar el test de carga

### 1. Obtener la URL del Service a través de minikube

> Es importante usar esta URL y no `kubectl port-forward`, ya que port-forward fija el tráfico a un único pod y no permite observar el balanceo real entre réplicas.

```bash
minikube service math-api --url
# Ejemplo de salida: http://192.168.49.2:31234
```

### 2. Ejecutar k6

```bash
k6 run -e BASE_URL=http://192.168.49.2:31234 stress.js
```

### 3. Observar el comportamiento del HPA en tiempo real

En otra terminal:

```bash
# Ver pods y consumo de CPU
watch kubectl top pods

# Ver estado del HPA
watch kubectl get hpa math-api-hpa
```

---

## Comportamiento esperado

1. Al iniciar el test, el pod único comienza a consumir CPU.
2. Cuando supera el 30% del CPU request, el HPA lanza nuevos pods.
3. A medida que los pods nuevos pasan a `Ready`, kube-proxy distribuye el tráfico entre todos.
4. Al terminar el test, el HPA reduce las réplicas gradualmente (máximo 50% cada 15s) hasta volver a 1.
