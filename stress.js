import http from 'k6/http';
import { check, sleep } from 'k6';

// Genera un valor con distribución exponencial.
// En un proceso de Poisson, el tiempo entre llegadas sigue una distribución
// exponencial con parámetro λ (rate). Esta función se usa para modelar
// la variabilidad en el costo de cada request.
function expRandom(rate) {
  return -Math.log(1 - Math.random()) / rate;
}

// Simula distintos tipos de usuarios con diferentes cargas de trabajo.
// La mayoría pide límites bajos (requests baratos), unos pocos piden
// límites altos (requests costosos en CPU) — distribución realista.
function randomLimit() {
  const buckets = [
    { limit: 100_000, weight: 0.40 },
    { limit: 250_000, weight: 0.30 },
    { limit: 500_000, weight: 0.20 },
    { limit: 750_000, weight: 0.07 },
    { limit: 1_000_000, weight: 0.03 },
  ];
  const r = Math.random();
  let cumulative = 0;
  for (const bucket of buckets) {
    cumulative += bucket.weight;
    if (r < cumulative) return bucket.limit;
  }
  return 500_000;
}

export const options = {
  scenarios: {
    // ramping-arrival-rate controla llegadas por segundo, no VUs.
    // Esto modela un proceso de Poisson: la tasa λ varía en el tiempo
    // pero dentro de cada intervalo las llegadas son aleatorias e independientes.
    poisson_traffic: {
      executor: 'ramping-arrival-rate',
      startRate: 5,         // req/s al inicio
      timeUnit: '1s',
      preAllocatedVUs: 100, // VUs pre-creados para no pagar latencia de arranque
      maxVUs: 500,          // techo de VUs si el sistema es lento y se acumulan
      stages: [
        { duration: '30s', target: 20  }, // ramp up:  5 → 20  req/s
        { duration: '2m',  target: 100 }, // carga media: → 100 req/s
        { duration: '2m',  target: 200 }, // pico: → 200 req/s
        { duration: '30s', target: 0   }, // ramp down
      ],
    },
  },
  noConnectionReuse: true,
};

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8080';

export default function () {
  const limit = randomLimit();

  // El tiempo de proceso de cada request varía aleatoriamente (exponencial),
  // simulando que distintos usuarios tienen distinta latencia de red/cliente.
  const thinkTime = expRandom(2); // media = 0.5s

  const res = http.get(`${BASE_URL}/primes?limit=${limit}`, {
    tags: { limit_bucket: String(limit) },
  });

  check(res, {
    'status 200':   (r) => r.status === 200,
    'tiene count':  (r) => JSON.parse(r.body).count > 0,
  });

  // Think time exponencial: pausa variable entre requests del mismo VU,
  // evitando el patrón artificial de sleep fijo.
  // No afecta la tasa de llegada (controlada por ramping-arrival-rate).
  sleep(thinkTime);
}
