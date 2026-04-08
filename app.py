import asyncio
import json
import os
import time
import uuid

import aio_pika
import redis.asyncio as redis
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

app = FastAPI(title="Math API")

RABBITMQ_URL      = os.getenv("RABBITMQ_URL", "amqp://guest:guest@rabbitmq/")
REDIS_URL         = os.getenv("REDIS_URL",    "redis://redis:6379")
MAX_CONCURRENT_PUBLISHES = int(os.getenv("MAX_CONCURRENT_PUBLISHES", "50"))

_redis:   redis.Redis        = None
_rmq_conn: aio_pika.RobustConnection = None
_channel:  aio_pika.Channel  = None
_publish_semaphore: asyncio.Semaphore | None = None


@app.on_event("startup")
async def startup():
    global _redis, _rmq_conn, _channel, _publish_semaphore
    _redis             = redis.from_url(REDIS_URL, decode_responses=True)
    _publish_semaphore = asyncio.Semaphore(MAX_CONCURRENT_PUBLISHES)

    for attempt in range(10):
        try:
            _rmq_conn = await aio_pika.connect_robust(RABBITMQ_URL)
            _channel  = await _rmq_conn.channel()
            await _channel.declare_queue("tasks", durable=True)
            return
        except Exception as e:
            if attempt < 9:
                print(f"RabbitMQ no disponible, reintentando en 3s... ({e})", flush=True)
                await asyncio.sleep(3)
            else:
                raise


@app.on_event("shutdown")
async def shutdown():
    await _rmq_conn.close()
    await _redis.aclose()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/primes", status_code=202)
async def submit_primes(limit: int = Query(default=500_000, ge=2, le=5_000_000)):
    """
    Publica un trabajo en la cola y devuelve un task_id para consultar el resultado.
    """
    task_id = str(uuid.uuid4())

    async with _publish_semaphore:
        await asyncio.wait_for(
            _channel.default_exchange.publish(
                aio_pika.Message(
                    body=json.dumps({"task_id": task_id, "limit": limit, "published_at": time.time()}).encode(),
                    delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                ),
                routing_key="tasks",
            ),
            timeout=2.0,
        )

    await _redis.set(f"task:{task_id}", json.dumps({"status": "pending"}))

    return {"task_id": task_id, "status": "pending"}


@app.get("/primes/{task_id}")
async def get_result(task_id: str):
    """
    Consulta el resultado de un trabajo. Devuelve 404 si el task_id no existe.
    """
    data = await _redis.get(f"task:{task_id}")
    if data is None:
        return JSONResponse(status_code=404, content={"error": "task not found"})
    return json.loads(data)
