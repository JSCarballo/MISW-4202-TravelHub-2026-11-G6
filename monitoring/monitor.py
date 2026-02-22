from __future__ import annotations
import argparse
import json
import logging
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Dict, Optional, Set
import requests


UPSTREAM_PATH = "./monitoring/nginx/upstream.conf"


# ── Event log for metrics / demo ──────────────────────────────────
events_log: list[dict] = []


def log_event(event_type: str, instance: str, detail: str = "") -> None:
    """Append a timestamped event for later analysis."""
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "epoch": time.time(),
        "event": event_type,
        "instance": instance,
        "detail": detail,
    }
    events_log.append(entry)
    logging.info("EVENT  %-20s  instance=%-25s  %s", event_type, instance, detail)


# ── Prometheus helpers ─────────────────────────────────────────────
def query_prom(prom_url: str, query: str, timeout: float = 5.0) -> Optional[dict]:
    try:
        r = requests.get(f"{prom_url.rstrip('/')}/api/v1/query", params={"query": query}, timeout=timeout)
        r.raise_for_status()
        return r.json()
    except Exception as exc:
        logging.debug("Prometheus query failed: %s", exc)
        return None


def parse_inventory_states(prom_json: dict) -> Dict[str, float]:
    """
    Parse Prometheus instant-query response for inventory_service_state.
    Returns {instance: value} e.g. {"api-inventory-1:8000": 1.0}
    """
    out: Dict[str, float] = {}
    if not prom_json or prom_json.get("status") != "success":
        return out
    for item in prom_json.get("data", {}).get("result", []):
        metric = item.get("metric", {})
        instance = metric.get("instance") or metric.get("job")
        try:
            value = float(item.get("value", [])[1])
        except Exception:
            continue
        if instance:
            out[instance] = value
    return out


# ── Nginx upstream manipulation ───────────────────────────────────
def comment_server_in_upstream(instance: str, dry_run: bool = True) -> bool:
    try:
        with open(UPSTREAM_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        logging.error("Upstream file not found: %s", UPSTREAM_PATH)
        return False

    changed = False
    new_lines = []
    for ln in lines:
        stripped = ln.strip()
        if instance in ln and stripped.startswith("server") and not stripped.startswith("#"):
            new_lines.append(f"# removed-by-monitor:{instance} " + ln.lstrip())
            changed = True
        else:
            new_lines.append(ln)

    if not changed:
        return False

    if dry_run:
        logging.info("Dry-run: would comment %s in upstream", instance)
        return True

    with open(UPSTREAM_PATH, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    logging.info("Upstream updated: commented %s", instance)
    return True


def restore_server_in_upstream(instance: str, dry_run: bool = True) -> bool:
    try:
        with open(UPSTREAM_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        logging.error("Upstream file not found: %s", UPSTREAM_PATH)
        return False

    marker = f"# removed-by-monitor:{instance} "
    changed = False
    new_lines = []
    for ln in lines:
        if ln.startswith(marker):
            new_lines.append("    " + ln[len(marker):])
            changed = True
        else:
            new_lines.append(ln)

    if not changed:
        return False

    if dry_run:
        logging.info("Dry-run: would restore %s in upstream", instance)
        return True

    with open(UPSTREAM_PATH, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    logging.info("Upstream updated: restored %s", instance)
    return True


def reload_nginx(dry_run: bool = True) -> bool:
    cmd = ["docker", "compose", "exec", "-T", "nginx", "nginx", "-s", "reload"]
    logging.info("Reloading nginx: %s", " ".join(cmd))
    if dry_run:
        logging.info("Dry-run: not executing reload")
        return True
    try:
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if result.returncode != 0:
            logging.error("Nginx reload failed (rc=%d): %s", result.returncode, result.stderr)
            return False
        logging.info("Nginx reload successful")
        return True
    except Exception as exc:
        logging.error("Failed to reload nginx: %s", exc)
        return False


# ── Main loop ─────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Monitor: detecta degradación y retira instancias del upstream de Nginx"
    )
    parser.add_argument("--prometheus-url", default="http://localhost:9090")
    parser.add_argument("--poll-interval", type=float, default=3.0,
                        help="Segundos entre health-checks (default 3)")
    parser.add_argument("--consecutive", type=int, default=2,
                        help="Muestras consecutivas para confirmar degradación (default 2, =6s con poll=3)")
    parser.add_argument("--threshold", type=float, default=1.0,
                        help="Valor mínimo de inventory_service_state para considerar degradado")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--events-file", default="monitoring/events.json",
                        help="Archivo donde guardar el log de eventos al terminar")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    # Counters per instance: how many consecutive polls above threshold
    state_counters: Dict[str, int] = {}
    # Set of instances currently removed from upstream
    removed_instances: Set[str] = set()

    query = "inventory_service_state"

    logging.info("Monitor started: poll=%.1fs, consecutive=%d, threshold=%.1f, dry_run=%s",
                 args.poll_interval, args.consecutive, args.threshold, args.dry_run)
    logging.info("Querying Prometheus at %s  metric=%s", args.prometheus_url, query)

    # ── Signal handler: save events on SIGTERM (sent by kill) ──
    def _save_and_exit(signum, frame):
        logging.info("Received signal %s, saving events and exiting ...", signum)
        if events_log:
            try:
                with open(args.events_file, "w", encoding="utf-8") as f:
                    json.dump(events_log, f, indent=2)
                logging.info("Events log saved to %s (%d events)", args.events_file, len(events_log))
            except Exception as exc:
                logging.error("Failed to save events log: %s", exc)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _save_and_exit)
    signal.signal(signal.SIGINT, _save_and_exit)

    try:
        while True:
            # ── Query Prometheus for inventory_service_state ──
            j = query_prom(args.prometheus_url, query)
            states = parse_inventory_states(j)
            logging.debug("States: %s | Removed: %s | Counters: %s", states, removed_instances, state_counters)

            for inst, val in states.items():
                # ── Detection: count consecutive degraded samples ──
                if val >= args.threshold:
                    state_counters[inst] = state_counters.get(inst, 0) + 1

                    if inst not in removed_instances and state_counters[inst] >= args.consecutive:
                        log_event("DEGRADATION_CONFIRMED", inst, f"value={val} count={state_counters[inst]}")
                        changed = comment_server_in_upstream(inst, dry_run=args.dry_run)
                        if changed:
                            reload_nginx(dry_run=args.dry_run)
                            removed_instances.add(inst)
                            log_event("REMOVED_FROM_UPSTREAM", inst)
                else:
                    # Instance reports healthy
                    if state_counters.get(inst, 0) > 0:
                        state_counters[inst] = 0

                    # ── Restoration: only if this specific instance was removed ──
                    if inst in removed_instances:
                        log_event("HEALTHY_AGAIN", inst, f"value={val}")
                        restored = restore_server_in_upstream(inst, dry_run=args.dry_run)
                        if restored:
                            reload_nginx(dry_run=args.dry_run)
                            removed_instances.discard(inst)
                            log_event("RESTORED_TO_UPSTREAM", inst)

            time.sleep(args.poll_interval)

    except KeyboardInterrupt:
        logging.info("Monitor interrupted by user")

    # Save events log
    if events_log:
        try:
            with open(args.events_file, "w", encoding="utf-8") as f:
                json.dump(events_log, f, indent=2)
            logging.info("Events log saved to %s (%d events)", args.events_file, len(events_log))
        except Exception as exc:
            logging.error("Failed to save events log: %s", exc)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
