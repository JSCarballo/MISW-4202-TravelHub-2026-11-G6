import os
from contextlib import closing
from datetime import datetime
from decimal import Decimal

import psycopg2
from flask import Flask, jsonify, request
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

ALLOWED_STATUS = {"pending", "confirmed", "cancelled"}
REQUIRED_FIELDS = {"user_id", "sku", "item_name", "quantity", "total_price"}


def db_settings() -> dict:
    return {
        "host": os.getenv("DB_HOST", "postgres"),
        "port": int(os.getenv("DB_PORT", "5432")),
        "dbname": os.getenv("DB_NAME", "booking_db"),
        "user": os.getenv("DB_USER", "bookinguser"),
        "password": os.getenv("DB_PASSWORD", "reservas_pass_123"),
        "application_name": os.getenv("DB_APPLICATION_NAME", "reservas-ms"),
        "connect_timeout": 3,
    }


def get_connection():
    return psycopg2.connect(**db_settings())


def serialize_booking(row: dict) -> dict:
    payload = {}
    for key, value in row.items():
        if isinstance(value, Decimal):
            payload[key] = float(value)
        elif isinstance(value, datetime):
            payload[key] = value.isoformat()
        else:
            payload[key] = value
    return payload


def validate_booking_payload(payload: dict) -> str | None:
    missing = sorted(REQUIRED_FIELDS - payload.keys())
    if missing:
        return f"missing fields: {', '.join(missing)}"

    if not isinstance(payload["user_id"], int):
        return "user_id must be an integer"
    if not isinstance(payload["quantity"], int) or payload["quantity"] < 1:
        return "quantity must be a positive integer"
    if not isinstance(payload["total_price"], (int, float)):
        return "total_price must be numeric"
    if not all(isinstance(payload[field], str) and payload[field].strip() for field in ("sku", "item_name")):
        return "sku and item_name must be non-empty strings"
    return None


def fetch_booking(booking_id: int) -> dict | None:
    with closing(get_connection()) as conn, conn, conn.cursor(cursor_factory=RealDictCursor) as cursor:
        cursor.execute(
            """
            SELECT id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at
            FROM booking
            WHERE id = %s
            """,
            (booking_id,),
        )
        row = cursor.fetchone()
    return serialize_booking(row) if row else None


@app.get("/health")
def health():
    settings = db_settings()
    try:
        with closing(get_connection()) as conn, conn.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except psycopg2.Error as exc:
        return (
            jsonify(
                {
                    "service": "reservas",
                    "healthy": False,
                    "db_user": settings["user"],
                    "application_name": settings["application_name"],
                    "error": str(exc).strip(),
                }
            ),
            503,
        )

    return (
        jsonify(
            {
                "service": "reservas",
                "healthy": True,
                "db_user": settings["user"],
                "application_name": settings["application_name"],
            }
        ),
        200,
    )


@app.post("/reservas")
def create_booking():
    payload = request.get_json(silent=True) or {}
    error = validate_booking_payload(payload)
    if error:
        return jsonify({"error": error}), 400

    try:
        with closing(get_connection()) as conn, conn, conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                INSERT INTO booking (
                    user_id,
                    sku,
                    item_name,
                    quantity,
                    status,
                    total_price,
                    updated_at
                )
                VALUES (%s, %s, %s, %s, 'pending', %s, NOW())
                RETURNING id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at
                """,
                (
                    payload["user_id"],
                    payload["sku"].strip(),
                    payload["item_name"].strip(),
                    payload["quantity"],
                    payload["total_price"],
                ),
            )
            row = cursor.fetchone()
    except psycopg2.Error as exc:
        return jsonify({"error": "database write failed", "detail": str(exc).strip()}), 503

    return jsonify(serialize_booking(row)), 201


@app.get("/reservas/<int:booking_id>")
def get_booking(booking_id: int):
    try:
        booking = fetch_booking(booking_id)
    except psycopg2.Error as exc:
        return jsonify({"error": "database read failed", "detail": str(exc).strip()}), 503

    if not booking:
        return jsonify({"error": "booking not found"}), 404
    return jsonify(booking), 200


@app.patch("/reservas/<int:booking_id>/status")
def update_booking_status(booking_id: int):
    payload = request.get_json(silent=True) or {}
    status = payload.get("status")
    if status not in ALLOWED_STATUS:
        return jsonify({"error": "invalid status", "allowed": sorted(ALLOWED_STATUS)}), 400

    try:
        with closing(get_connection()) as conn, conn, conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                """
                UPDATE booking
                SET status = %s, updated_at = NOW()
                WHERE id = %s
                RETURNING id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at
                """,
                (status, booking_id),
            )
            row = cursor.fetchone()
    except psycopg2.Error as exc:
        return jsonify({"error": "database update failed", "detail": str(exc).strip()}), 503

    if not row:
        return jsonify({"error": "booking not found"}), 404
    return jsonify(serialize_booking(row)), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
