import random
import threading
import time

from flask import Flask, Response, jsonify, request, g
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

app = Flask(__name__)

STATE_VALUES = {"healthy": 0, "degraded": 1, "down": 2}
state_lock = threading.Lock()
service_state = {"value": "healthy"}

REQUEST_COUNT = Counter(
    "inventory_http_requests_total",
    "Total HTTP requests handled by inventory service",
    ["endpoint", "method", "status"],
)
REQUEST_LATENCY = Histogram(
    "inventory_http_request_duration_seconds",
    "HTTP request latency in seconds for inventory service",
    ["endpoint"],
)
SERVICE_STATE = Gauge(
    "inventory_service_state",
    "Current service state where healthy=0, degraded=1, down=2",
)
SERVICE_STATE.set(STATE_VALUES["healthy"])

INVENTORY_SAMPLE = [
    {"sku": "HTL-001", "name": "Hotel Cartagena", "available": 14},
    {"sku": "FLT-002", "name": "Vuelo Bogota-Medellin", "available": 26},
    {"sku": "CAR-003", "name": "Renta auto compacta", "available": 9},
]


def get_state() -> str:
    with state_lock:
        return service_state["value"]


def set_state(new_state: str) -> None:
    with state_lock:
        service_state["value"] = new_state
    SERVICE_STATE.set(STATE_VALUES[new_state])


@app.before_request
def start_timer() -> None:
    g.request_start_time = time.perf_counter()


@app.after_request
def record_metrics(response):
    duration = time.perf_counter() - g.request_start_time
    endpoint = request.path
    REQUEST_COUNT.labels(
        endpoint=endpoint, method=request.method, status=str(response.status_code)
    ).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(duration)
    return response


@app.get("/health")
def health():
    state = get_state()
    payload = {"service": "inventory", "state": state, "healthy": state == "healthy"}

    if state == "down":
        time.sleep(3)
        return jsonify(payload), 500
    if state == "degraded":
        return jsonify(payload), 503
    return jsonify(payload), 200


@app.get("/inventario")
def inventario():
    state = get_state()

    if state == "down":
        time.sleep(3)
        return jsonify({"error": "service unavailable", "state": state}), 500

    if state == "degraded":
        if random.random() < 0.5:
            return jsonify({"error": "intermittent inventory error", "state": state}), 500
        time.sleep(1)

    return jsonify({"state": state, "items": INVENTORY_SAMPLE}), 200


@app.get("/admin/state")
def get_admin_state():
    return jsonify({"state": get_state()}), 200


@app.post("/admin/state")
def update_admin_state():
    content = request.get_json(silent=True) or {}
    new_state = content.get("state")
    if new_state not in STATE_VALUES:
        return (
            jsonify(
                {
                    "error": "invalid state",
                    "allowed": list(STATE_VALUES.keys()),
                }
            ),
            400,
        )

    set_state(new_state)
    return jsonify({"state": new_state}), 200


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
