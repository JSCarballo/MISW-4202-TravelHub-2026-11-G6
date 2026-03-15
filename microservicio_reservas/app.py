from flask import Flask, request, jsonify
import psycopg2
import os

app = Flask(__name__)

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "postgres"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "database": os.getenv("DB_NAME", "booking_db"),
    "user": os.getenv("DB_USER", "bookinguser"),
    "password": os.getenv("DB_PASSWORD", "reservas_pass_123"),
}


def get_conn():
    return psycopg2.connect(**DB_CONFIG)


@app.route("/health", methods=["GET"])
def health():
    try:
        conn = get_conn()
        conn.close()
        return jsonify({"status": "healthy"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 503


@app.route("/bookings", methods=["GET"])
def list_bookings():
    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        "SELECT id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at "
        "FROM booking ORDER BY id"
    )
    rows = cur.fetchall()
    cols = [d[0] for d in cur.description]
    cur.close()
    conn.close()
    return jsonify([dict(zip(cols, r)) for r in rows]), 200


@app.route("/bookings", methods=["POST"])
def create_booking():
    data = request.get_json()
    required = ["user_id", "sku", "item_name", "total_price"]
    for field in required:
        if field not in data:
            return jsonify({"error": f"Campo requerido: {field}"}), 400

    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO booking (user_id, sku, item_name, quantity, status, total_price) "
        "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
        (
            data["user_id"],
            data["sku"],
            data["item_name"],
            data.get("quantity", 1),
            data.get("status", "pending"),
            data["total_price"],
        ),
    )
    booking_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({"id": booking_id, "message": "Reserva creada"}), 201


@app.route("/bookings/<int:booking_id>", methods=["PUT"])
def update_booking(booking_id):
    data = request.get_json()
    fields = []
    values = []
    for col in ["status", "quantity", "total_price"]:
        if col in data:
            fields.append(f"{col} = %s")
            values.append(data[col])
    if not fields:
        return jsonify({"error": "No hay campos para actualizar"}), 400

    fields.append("updated_at = NOW()")
    values.append(booking_id)

    conn = get_conn()
    cur = conn.cursor()
    cur.execute(
        f"UPDATE booking SET {', '.join(fields)} WHERE id = %s", values
    )
    if cur.rowcount == 0:
        cur.close()
        conn.close()
        return jsonify({"error": "Reserva no encontrada"}), 404
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({"message": "Reserva actualizada"}), 200


@app.route("/bookings/<int:booking_id>", methods=["DELETE"])
def delete_booking(booking_id):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("DELETE FROM booking WHERE id = %s", (booking_id,))
    if cur.rowcount == 0:
        cur.close()
        conn.close()
        return jsonify({"error": "Reserva no encontrada"}), 404
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({"message": "Reserva eliminada"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
