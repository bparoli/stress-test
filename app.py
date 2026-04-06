from fastapi import FastAPI, Query
import math

app = FastAPI(title="Math API")


def sieve_of_eratosthenes(limit: int) -> list[int]:
    """Returns all primes up to limit using the Sieve of Eratosthenes."""
    if limit < 2:
        return []
    sieve = bytearray([1]) * (limit + 1)
    sieve[0] = sieve[1] = 0
    for i in range(2, int(math.isqrt(limit)) + 1):
        if sieve[i]:
            sieve[i * i :: i] = bytearray(len(sieve[i * i :: i]))
    return [i for i, v in enumerate(sieve) if v]


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/primes")
def primes(limit: int = Query(default=500_000, ge=2, le=5_000_000)):
    """
    Returns the count and last prime up to `limit`.
    Default limit=500_000 provides a CPU-intensive but bounded workload.
    """
    result = sieve_of_eratosthenes(limit)
    return {
        "limit": limit,
        "count": len(result),
        "largest_prime": result[-1] if result else None,
    }
