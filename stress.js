import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const queueWait = new Trend('queue_wait_ms', true);

// Genera un valor con distribución exponencial.
// En un proceso de Poisson, el tiempo entre llegadas sigue una distribución
// exponencial con parámetro λ (rate).
function expRandom(rate) {
  return -Math.log(1 - Math.random()) / rate;
}

// Simula distintos tipos de usuarios con diferentes cargas de trabajo.
// La mayoría pide límites bajos (requests baratos), unos pocos piden
// límites altos (requests costosos en CPU) — distribución realista.
function randomLimit() {
  const buckets = [
    { limit: 100_000,   weight: 0.40 },
    { limit: 250_000,   weight: 0.30 },
    { limit: 500_000,   weight: 0.20 },
    { limit: 750_000,   weight: 0.07 },
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
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      //maxVUs: 500,
      maxVUs: 200,
      stages: [
        { duration: '30s', target: 20  },
        { duration: '2m',  target: 100 },
        { duration: '2m',  target: 200 },
        { duration: '2m', target: 0   },
      ],
    },
  },
  noConnectionReuse: true,
};

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8080';

export default function () {
  const limit = randomLimit();

  // 1. Enviar trabajo a la cola
  const submitRes = http.post(
    `${BASE_URL}/primes?limit=${limit}`,
    null,
    { tags: { phase: 'submit', limit_bucket: String(limit) } },
  );

  const submitted = check(submitRes, {
    'submit 202': (r) => r.status === 202,
    'tiene task_id': (r) => JSON.parse(r.body).task_id !== undefined,
  });

  if (!submitted) return;

  const taskId = JSON.parse(submitRes.body).task_id;

  // 2. Polling hasta obtener resultado (máximo 30 intentos, cada 0.5s)
  let done = false;
  for (let i = 0; i < 30; i++) {
    sleep(0.5);

    const pollRes = http.get(
      `${BASE_URL}/primes/${taskId}`,
      { tags: { phase: 'poll', name: 'GET /primes/:id' } },
    );

    if (pollRes.status === 200) {
      const body = JSON.parse(pollRes.body);
      if (body.status === 'done') {
        check(pollRes, { 'resultado correcto': () => body.count > 0 });
        if (body.queue_wait_s !== undefined) {
          queueWait.add(body.queue_wait_s * 1000);
        }
        done = true;
        break;
      }
    }
  }

  check(null, { 'tarea completada': () => done });

  // Think time exponencial: pausa variable entre requests del mismo VU.
  sleep(expRandom(2));
}
