"""
Componente Auditor – Security Monitor
======================================
Detecta operaciones fraudulentas en la BD analizando PATRONES en audit_log:
  - Patrón 1: Ráfaga de UPDATEs al mismo registro en poco tiempo
  - Patrón 2: Cambio anómalo de precio (reducción > 50%)
  - Patrón 3: Operaciones desde un usuario que no es el del microservicio

Al detectar fraude:
  1. Registra las anomalías detectadas
  2. Bloquea al usuario (REVOKE CONNECT + ALL PRIVILEGES)
  3. Revierte los cambios usando old_data del audit_log
"""

import time
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import requests
import psycopg2

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("auditor")

# ── Config ────────────────────────────────────────────────────────
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "5"))

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "postgres"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "database": os.getenv("DB_NAME", "booking_db"),
    "user": os.getenv("DB_USER", "admin"),
    "password": os.getenv("DB_PASSWORD", "adminTravelHub"),
}

# Umbrales de detección
BURST_THRESHOLD = 3          # N updates al mismo registro en la ventana
PRICE_CHANGE_THRESHOLD = 0.5 # reducción de precio > 50% es sospechosa
VOLUME_THRESHOLD = 5         # N+ operaciones totales por un usuario en la ventana
TIME_WINDOW_SECONDS = 30

# Track state
blocked_users: set[str] = set()
reverted_ids: set[int] = set()
analyzed_ids: set[int] = set()
events: list[dict] = []


def record_event(event_type: str, detail: str):
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event_type,
        "detail": detail,
    }
    events.append(entry)
    log.info("[%s] %s", event_type, detail)


def get_admin_conn():
    return psycopg2.connect(**DB_CONFIG)


# ── 1. Detectar patrones anómalos en audit_log ──────────────────
def detect_anomalies(conn) -> dict[str, list[str]]:
    """
    Analiza audit_log buscando patrones sospechosos.
    Retorna {username: [lista de razones de detección]}
    """
    cur = conn.cursor()
    suspicious_users: dict[str, list[str]] = {}

    # ── Patrón 1: Ráfaga de UPDATEs al mismo registro ────────────
    # Si un usuario hizo N+ updates al mismo registro en la ventana, es sospechoso
    cur.execute(
        "SELECT changed_by, table_name, "
        "  (new_data->>'id')::int AS record_id, "
        "  COUNT(*) AS update_count "
        "FROM audit.audit_log "
        "WHERE operations = 'U' "
        "  AND changed_at > NOW() - INTERVAL '%s seconds' "
        "GROUP BY changed_by, table_name, new_data->>'id' "
        "HAVING COUNT(*) >= %s",
        (TIME_WINDOW_SECONDS, BURST_THRESHOLD),
    )
    for user, table, record_id, count in cur.fetchall():
        if user in blocked_users:
            continue
        reason = (
            f"RAFAGA: {count} UPDATEs al registro {table}.id={record_id} "
            f"en {TIME_WINDOW_SECONDS}s (umbral: {BURST_THRESHOLD})"
        )
        suspicious_users.setdefault(user, []).append(reason)

    # ── Patrón 2: Cambio anómalo de precio ────────────────────────
    # Comparar old_data.total_price vs new_data.total_price
    cur.execute(
        "SELECT id, changed_by, "
        "  (old_data->>'total_price')::numeric AS old_price, "
        "  (new_data->>'total_price')::numeric AS new_price "
        "FROM audit.audit_log "
        "WHERE operations = 'U' "
        "  AND old_data->>'total_price' IS NOT NULL "
        "  AND new_data->>'total_price' IS NOT NULL "
        "  AND changed_at > NOW() - INTERVAL '%s seconds' ",
        (TIME_WINDOW_SECONDS,),
    )
    for audit_id, user, old_price, new_price in cur.fetchall():
        if user in blocked_users or audit_id in analyzed_ids:
            continue
        analyzed_ids.add(audit_id)
        if old_price > 0:
            reduction = float((old_price - new_price) / old_price)
            if reduction > PRICE_CHANGE_THRESHOLD:
                reason = (
                    f"PRECIO ANOMALO: ${old_price} -> ${new_price} "
                    f"(reducción {reduction:.0%}, umbral: {PRICE_CHANGE_THRESHOLD:.0%})"
                )
                suspicious_users.setdefault(user, []).append(reason)

    # ── Patrón 3: Volumen alto de operaciones por usuario ────────
    # Detecta un usuario haciendo muchas operaciones en distintas filas
    cur.execute(
        "SELECT changed_by, COUNT(*) AS total_ops, "
        "  COUNT(DISTINCT (new_data->>'id')) AS distinct_rows "
        "FROM audit.audit_log "
        "WHERE changed_at > NOW() - INTERVAL '%s seconds' "
        "GROUP BY changed_by "
        "HAVING COUNT(*) >= %s",
        (TIME_WINDOW_SECONDS, VOLUME_THRESHOLD),
    )
    for user, total_ops, distinct_rows in cur.fetchall():
        if user in blocked_users:
            continue
        reason = (
            f"VOLUMEN ALTO: {total_ops} operaciones sobre {distinct_rows} "
            f"registro(s) en {TIME_WINDOW_SECONDS}s (umbral: {VOLUME_THRESHOLD})"
        )
        suspicious_users.setdefault(user, []).append(reason)

    cur.close()
    return suspicious_users


# ── 2. Consultar alertas de Prometheus ────────────────────────────
def get_firing_alerts() -> list[dict]:
    try:
        resp = requests.get(f"{PROMETHEUS_URL}/api/v1/alerts", timeout=5)
        resp.raise_for_status()
        data = resp.json()["data"]["alerts"]
        return [
            a for a in data
            if a["state"] == "firing"
            and a["labels"].get("alertname", "").startswith("Audit")
        ]
    except Exception as e:
        log.warning("No se pudo consultar Prometheus: %s", e)
        return []


# ── 3. Bloquear usuario ──────────────────────────────────────────
def block_user(conn, username: str):
    if username in blocked_users:
        return
    cur = conn.cursor()
    cur.execute(
        f"REVOKE CONNECT ON DATABASE booking_db FROM {username};"
    )
    cur.execute(
        f"REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM {username};"
    )
    conn.commit()
    cur.close()
    blocked_users.add(username)
    record_event("USER_BLOCKED", f"Usuario '{username}' bloqueado (REVOKE CONNECT + ALL PRIVILEGES)")


# ── 4. Revertir cambios ──────────────────────────────────────────
def revert_changes(conn, username: str):
    cur = conn.cursor()
    cur.execute(
        "SELECT id, table_name, operations, old_data, new_data "
        "FROM audit.audit_log "
        "WHERE changed_by = %s "
        "AND changed_at > NOW() - INTERVAL '%s seconds' "
        "ORDER BY changed_at ASC",
        (username, TIME_WINDOW_SECONDS),
    )
    rows = cur.fetchall()
    reverted = 0
    reverted_pks: set[tuple[str, int]] = set()

    for audit_id, table_name, op, old_data, new_data in rows:
        if audit_id in reverted_ids:
            continue

        if op == "U" and old_data:
            pk = old_data.get("id")
            if pk is None:
                continue
            key = (table_name, pk)
            if key in reverted_pks:
                reverted_ids.add(audit_id)
                continue
            set_clauses = []
            values = []
            for col, val in old_data.items():
                if col == "id":
                    continue
                set_clauses.append(f"{col} = %s")
                values.append(val)
            if set_clauses:
                values.append(pk)
                cur.execute(
                    f"UPDATE public.{table_name} SET {', '.join(set_clauses)} WHERE id = %s",
                    values,
                )
                reverted += 1
            reverted_pks.add(key)

        elif op == "I" and new_data:
            pk = new_data.get("id")
            if pk:
                cur.execute(f"DELETE FROM public.{table_name} WHERE id = %s", (pk,))
                reverted += 1

        elif op == "D" and old_data:
            cols = list(old_data.keys())
            vals = [old_data[c] for c in cols]
            placeholders = ", ".join(["%s"] * len(vals))
            cur.execute(
                f"INSERT INTO public.{table_name} ({', '.join(cols)}) VALUES ({placeholders})",
                vals,
            )
            reverted += 1

        reverted_ids.add(audit_id)

    conn.commit()
    cur.close()
    if reverted > 0:
        record_event("CHANGES_REVERTED", f"{reverted} cambios de '{username}' revertidos")


# ── 5. Terminar conexiones activas del usuario ────────────────────
def terminate_user_connections(conn, username: str):
    cur = conn.cursor()
    cur.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE usename = %s AND pid <> pg_backend_pid()",
        (username,),
    )
    terminated = cur.rowcount
    conn.commit()
    cur.close()
    if terminated > 0:
        record_event("CONNECTIONS_TERMINATED", f"{terminated} conexiones de '{username}' terminadas")


# ── Loop principal ────────────────────────────────────────────────
def main():
    log.info("Auditor Security Monitor iniciado")
    log.info(
        "Prometheus: %s | Poll: %ds | Ventana: %ds | Detección por patrones: "
        "ráfaga >= %d UPDATEs misma fila, reducción precio > %d%%, "
        "volumen >= %d ops totales",
        PROMETHEUS_URL, POLL_INTERVAL, TIME_WINDOW_SECONDS,
        BURST_THRESHOLD, int(PRICE_CHANGE_THRESHOLD * 100),
        VOLUME_THRESHOLD,
    )

    while True:
        try:
            conn = get_admin_conn()

            # Analizar patrones anómalos en audit_log
            suspicious = detect_anomalies(conn)

            # También verificar alertas de Prometheus
            alerts = get_firing_alerts()
            if alerts:
                for alert in alerts:
                    record_event(
                        "PROMETHEUS_ALERT",
                        f"{alert['labels']['alertname']}: {alert['annotations'].get('summary', '')}"
                    )

            # Actuar sobre usuarios con patrones sospechosos
            for user, reasons in suspicious.items():
                if user not in blocked_users:
                    for reason in reasons:
                        record_event("ANOMALY_DETECTED", reason)
                    record_event(
                        "FRAUD_DETECTED",
                        f"Usuario '{user}' identificado por {len(reasons)} patrón(es) anómalo(s)"
                    )
                    # 1. Terminar conexiones activas
                    terminate_user_connections(conn, user)
                    # 2. Bloquear para evitar nuevas operaciones
                    block_user(conn, user)
                    # 3. Esperar a que transacciones en vuelo terminen
                    time.sleep(1)
                    # 4. Revertir con conexión fresca
                    conn2 = get_admin_conn()
                    revert_changes(conn2, user)
                    conn2.close()

            conn.close()
        except Exception as e:
            log.error("Error en ciclo principal: %s", e)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
