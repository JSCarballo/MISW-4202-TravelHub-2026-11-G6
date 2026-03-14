#!/bin/bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8004}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"
BOOKING_PAYLOAD='{"user_id": 8, "sku": "PKG-010", "item_name": "Paquete Santa Marta", "quantity": 2, "total_price": 420000}'
PATCH_PAYLOAD='{"status": "confirmed"}'

print_header() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

sql_as_user() {
    local db_user="$1"
    local db_password="$2"
    local sql="$3"
    docker compose exec -T "$POSTGRES_SERVICE" sh -lc \
        "export PGPASSWORD='$db_password'; psql -U '$db_user' -d booking_db -v ON_ERROR_STOP=1 -c \"$sql\""
}

fetch_booking_json() {
    local booking_id="$1"
    curl -fsS "$API_URL/reservas/$booking_id"
}

require_command curl
require_command docker
require_command python3

print_header "FASE 0: Validar PostgreSQL y microservicio de Reservas"
sql_as_user "admin" "adminTravelHub" "SELECT 1;"
curl -fsS "$API_URL/health"
echo
echo "Validacion de salud completada."

print_header "FASE 1: Estado inicial para evidencia"
sql_as_user "admin" "adminTravelHub" "SELECT id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at FROM booking WHERE id IN (1, 2) ORDER BY id;"

print_header "FASE 2: Crear reserva legitima por el canal autorizado"
create_response="$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$BOOKING_PAYLOAD" "$API_URL/reservas")"
echo "$create_response"
new_booking_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$create_response")"
echo "Nueva reserva creada con id=$new_booking_id"

print_header "FASE 3: Actualizar reserva legitima por el canal autorizado"
patch_response="$(curl -fsS -X PATCH -H 'Content-Type: application/json' -d "$PATCH_PAYLOAD" "$API_URL/reservas/$new_booking_id/status")"
echo "$patch_response"

print_header "FASE 4: Consultar el registro legitimo afectado"
fetch_booking_json "$new_booking_id"
echo

print_header "FASE 5: Ataque directo no autorizado con frauduser"
sql_as_user "frauduser" "fraude_pass_456" "UPDATE booking SET total_price = 999999.99 WHERE id = 2;"
sql_as_user "frauduser" "fraude_pass_456" "UPDATE booking SET status = 'cancelled', updated_at = NOW() WHERE id = 1;"

print_header "FASE 6: Evidencia before/after consultada como admin"
sql_as_user "admin" "adminTravelHub" "SELECT id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at FROM booking WHERE id IN (1, 2, $new_booking_id) ORDER BY id;"

print_header "FASE 7: Pendiente de integracion con Auditor"
echo "Repetir el POST y el PATCH anteriores cuando el Auditor/Prometheus del grupo este integrado."
echo "Resultado esperado: los cambios legitimos del microservicio no deben generar alertas."
echo "Los updates hechos con frauduser deben ser la entrada que si dispara alerta."
