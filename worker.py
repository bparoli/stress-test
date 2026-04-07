import json
import math
import os
import time

import pika
import redis

RABBITMQ_URL = os.getenv("RABBITMQ_URL", "amqp://guest:guest@rabbitmq/")
REDIS_URL    = os.getenv("REDIS_URL",    "redis://redis:6379")
RESULT_TTL   = int(os.getenv("RESULT_TTL", 3600))  # segundos

redis_client = redis.from_url(REDIS_URL, decode_responses=True)


def sieve_of_eratosthenes(limit: int) -> list[int]:
    if limit < 2:
        return []
    sieve = bytearray([1]) * (limit + 1)
    sieve[0] = sieve[1] = 0
    for i in range(2, int(math.isqrt(limit)) + 1):
        if sieve[i]:
            sieve[i * i :: i] = bytearray(len(sieve[i * i :: i]))
    return [i for i, v in enumerate(sieve) if v]


def process(ch, method, properties, body):
    message = json.loads(body)
    task_id = message["task_id"]
    limit   = message["limit"]

    print(f"[recibido] task_id={task_id} limit={limit}", flush=True)

    start   = time.monotonic()
    result  = sieve_of_eratosthenes(limit)
    elapsed = round(time.monotonic() - start, 4)

    redis_client.set(
        f"task:{task_id}",
        json.dumps({
            "status":        "done",
            "limit":         limit,
            "count":         len(result),
            "largest_prime": result[-1] if result else None,
            "elapsed_s":     elapsed,
        }),
        ex=RESULT_TTL,
    )

    ch.basic_ack(delivery_tag=method.delivery_tag)
    print(f"[completado] task_id={task_id} primos={len(result)} elapsed={elapsed}s", flush=True)


def main():
    params = pika.URLParameters(RABBITMQ_URL)
    params.heartbeat = 60
    params.blocked_connection_timeout = 30

    while True:
        try:
            print("Conectando a RabbitMQ...", flush=True)
            conn    = pika.BlockingConnection(params)
            channel = conn.channel()

            channel.queue_declare(queue="tasks", durable=True)
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(queue="tasks", on_message_callback=process)

            print("Worker listo. Esperando mensajes...", flush=True)
            channel.start_consuming()
        except pika.exceptions.AMQPConnectionError as e:
            print(f"[error] Conexión perdida: {e}. Reintentando en 5s...", flush=True)
            time.sleep(5)
        except Exception as e:
            print(f"[error] Error inesperado: {e}. Reintentando en 5s...", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
