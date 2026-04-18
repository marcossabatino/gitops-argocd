import asyncio
import random
import time
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="python-app")

# Prometheus metrics
http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'path', 'status']
)

http_request_duration = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['method', 'path', 'status'],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10)
)


@app.get("/health")
async def health():
    start = time.time()
    try:
        return JSONResponse(status_code=200, content={"status": "OK"})
    finally:
        duration = time.time() - start
        http_request_duration.labels(method="GET", path="/health", status="200").observe(duration)
        http_requests_total.labels(method="GET", path="/health", status="200").inc()


@app.get("/simulate-slow")
async def simulate_slow():
    start = time.time()
    try:
        sleep_time = (random.randint(1000, 3000)) / 1000.0
        await asyncio.sleep(sleep_time)
        return JSONResponse(status_code=200, content={"message": "Slow endpoint completed"})
    finally:
        duration = time.time() - start
        http_request_duration.labels(method="GET", path="/simulate-slow", status="200").observe(duration)
        http_requests_total.labels(method="GET", path="/simulate-slow", status="200").inc()


@app.get("/simulate-error")
async def simulate_error():
    start = time.time()
    try:
        if random.random() < 0.5:
            return JSONResponse(status_code=500, content={"error": "Internal Server Error"})
        return JSONResponse(status_code=200, content={"status": "OK"})
    finally:
        duration = time.time() - start
        status = 500 if random.random() < 0.5 else 200
        http_request_duration.labels(method="GET", path="/simulate-error", status=str(status)).observe(duration)
        http_requests_total.labels(method="GET", path="/simulate-error", status=str(status)).inc()


@app.get("/metrics")
async def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.on_event("startup")
async def startup_event():
    logger.info("Python app started")


@app.on_event("shutdown")
async def shutdown_event():
    logger.info("Python app shutting down")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
