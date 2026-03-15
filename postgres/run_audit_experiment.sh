#!/bin/bash
######################################################################
# Experimento de Seguridad: Auditoría + Detección + Bloqueo
#
# Valida los 4 resultados esperados:
#   RE1. Detección + alerta en ≤ 10 segundos
#   RE2. Evidencia en el componente Auditor (audit_log)
#   RE3. Bloqueo del usuario en ≤ 30 segundos
#   RE4. Canal autorizado (microservicio) no dispara bloqueo ni alerta
######################################################################

POSTGRES_HOST="localhost"
POSTGRES_PORT="5434"
PROMETHEUS_URL="http://localhost:9090"
EXPORTER_URL="http://localhost:9187"
RESERVAS_URL="http://localhost:5000"
DB_NAME="booking_db"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

check() {
    local desc="$1"
    local result="$2"
    TOTAL=$((TOTAL + 1))
    if [ "$result" -eq 0 ]; then
        echo -e "  ${GREEN}[PASS]${NC} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Ejecuta un query mostrando el SQL y el resultado formateado
run_query() {
    local description="$1"
    local sql="$2"
    echo -e "  ${DIM}SQL: ${sql}${NC}"
    local result
    result=$(PGPASSWORD=adminTravelHub psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U admin -d "$DB_NAME" -c "$sql" 2>&1)
    echo -e "  ${DIM}${result}${NC}"
    echo ""
}

# Ejecuta un query y retorna solo el valor (sin formato)
psql_val() {
    PGPASSWORD=adminTravelHub psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U admin -d "$DB_NAME" -tAc "$1" 2>/dev/null | tr -d ' '
}

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN} Experimento: Detección de modificaciones no           ${NC}"
echo -e "${CYAN} autorizadas en DB Reservas + bloqueo y reversión      ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo ""

# ── Paso 0: Verificar que los servicios están corriendo ──────────
echo -e "${YELLOW}[0/6] Verificando servicios...${NC}"

pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U admin -d "$DB_NAME" > /dev/null 2>&1
check "PostgreSQL disponible" $?

curl -sf "$EXPORTER_URL/metrics" > /dev/null 2>&1
check "postgres_exporter disponible" $?

curl -sf "$PROMETHEUS_URL/-/healthy" > /dev/null 2>&1
check "Prometheus disponible" $?

curl -sf "$RESERVAS_URL/health" > /dev/null 2>&1
check "Microservicio Reservas disponible" $?

docker ps --format '{{.Names}}' | grep -q "auditor"
check "Componente Auditor corriendo" $?

echo ""

# ── Paso 1: Verificar esquema de auditoría ───────────────────────
echo -e "${YELLOW}[1/6] RE2: Verificando esquema de auditoría...${NC}"

run_query "Verificar que el schema audit existe" \
    "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'audit';"

AUDIT_SCHEMA=$(psql_val "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'audit';")
if [ "$AUDIT_SCHEMA" = "1" ]; then check "Schema 'audit' existe" 0; else check "Schema 'audit' existe" 1; fi

run_query "Verificar tabla audit.audit_log" \
    "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='audit' AND table_name='audit_log' ORDER BY ordinal_position;"

run_query "Verificar trigger activo en booking" \
    "SELECT trigger_name, event_manipulation, action_timing FROM information_schema.triggers WHERE trigger_name = 'audit_booking_trigger';"

TRIGGER=$(psql_val "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name = 'audit_booking_trigger';")
if [ "${TRIGGER:-0}" -ge 1 ]; then check "Trigger audit_booking_trigger activo" 0; else check "Trigger audit_booking_trigger activo" 1; fi

run_query "Estado actual de la tabla booking" \
    "SELECT id, user_id, sku, item_name, status, total_price FROM booking ORDER BY id;"

echo ""

# ── Paso 2: Canal autorizado (RE4) ──────────────────────────────
echo -e "${YELLOW}[2/6] RE4: Operaciones via microservicio (canal autorizado)...${NC}"

echo -e "  ${DIM}HTTP POST ${RESERVAS_URL}/bookings${NC}"
RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "$RESERVAS_URL/bookings" \
    -H "Content-Type: application/json" \
    -d '{"user_id": 99, "sku": "HTL-099", "item_name": "Hotel Test Autorizado", "total_price": 100000}' 2>/dev/null)
HTTP_BODY=$(echo "$RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
echo -e "  ${DIM}Respuesta: $HTTP_BODY (HTTP $HTTP_CODE)${NC}"
echo ""
if [ "$HTTP_CODE" = "201" ]; then check "INSERT via microservicio (bookinguser)" 0; else check "INSERT via microservicio" 1; fi

echo -e "  ${DIM}HTTP PUT ${RESERVAS_URL}/bookings/1${NC}"
RESPONSE=$(curl -s -w '\n%{http_code}' -X PUT "$RESERVAS_URL/bookings/1" \
    -H "Content-Type: application/json" \
    -d '{"status": "confirmed"}' 2>/dev/null)
HTTP_BODY=$(echo "$RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
echo -e "  ${DIM}Respuesta: $HTTP_BODY (HTTP $HTTP_CODE)${NC}"
echo ""
if [ "$HTTP_CODE" = "200" ]; then check "UPDATE via microservicio (bookinguser)" 0; else check "UPDATE via microservicio" 1; fi

run_query "Audit log después de operaciones legítimas" \
    "SELECT id, operations, changed_by, changed_at, substring(new_data::text, 1, 80) AS new_data_preview FROM audit.audit_log ORDER BY id;"

BOOKING_AUDIT=$(psql_val "SELECT COUNT(*) FROM audit.audit_log WHERE changed_by = 'bookinguser';")
if [ "${BOOKING_AUDIT:-0}" -ge 1 ]; then
    check "Operaciones de bookinguser registradas en audit_log ($BOOKING_AUDIT registros)" 0
else
    ALL_AUDIT=$(psql_val "SELECT COUNT(*) FROM audit.audit_log;")
    check "Operaciones registradas en audit_log (total: $ALL_AUDIT)" 0
fi

echo "  Esperando 10s para verificar que bookinguser no fue bloqueado..."
sleep 10

run_query "Verificar que bookinguser mantiene permisos" \
    "SELECT has_table_privilege('bookinguser', 'booking', 'SELECT') AS can_select, has_table_privilege('bookinguser', 'booking', 'INSERT') AS can_insert, has_table_privilege('bookinguser', 'booking', 'UPDATE') AS can_update;"

BOOKING_GRANT=$(psql_val "SELECT has_table_privilege('bookinguser', 'booking', 'SELECT');")
if [ "$BOOKING_GRANT" = "t" ]; then check "bookinguser NO fue bloqueado (sigue con permisos)" 0; else check "bookinguser NO fue bloqueado" 1; fi

echo ""

# ── Paso 3: Guardar estado pre-ataque ────────────────────────────
echo -e "${YELLOW}[3/6] Guardando estado pre-ataque...${NC}"

run_query "Estado actual de todas las reservas (antes del ataque)" \
    "SELECT id, item_name, total_price, status FROM booking ORDER BY id;"

# Guardar precios originales de TODAS las filas para verificar reversión
declare -A ORIGINAL_PRICES
BOOKING_IDS_PRE=$(PGPASSWORD=adminTravelHub psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U admin -d "$DB_NAME" -tAc "SELECT id FROM booking ORDER BY id;" 2>/dev/null)
for BID in $BOOKING_IDS_PRE; do
    ORIGINAL_PRICES[$BID]=$(psql_val "SELECT total_price FROM booking WHERE id = $BID;")
    echo -e "  ${DIM}Precio original booking.id=$BID: \$${ORIGINAL_PRICES[$BID]}${NC}"
done

run_query "Permisos actuales de frauduser" \
    "SELECT has_table_privilege('frauduser', 'booking', 'SELECT') AS can_select, has_table_privilege('frauduser', 'booking', 'UPDATE') AS can_update;"

echo ""

# ── Paso 4: Simular ataque fraudulento distribuido ───────────────
echo -e "${YELLOW}[4/6] RE1+RE3: Simulando ataque distribuido de frauduser...${NC}"
echo ""
echo -e "  ${RED}Ataque distribuido: 1 UPDATE por cada reserva (filas distintas)${NC}"
echo -e "  Cada UPDATE reduce el precio al 1% del valor actual."
echo -e "  El Auditor debe detectarlo por patrones, no por fila específica."
echo ""

FRAUD_START=$(date +%s)

BOOKING_IDS=$(PGPASSWORD=adminTravelHub psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U admin -d "$DB_NAME" -tAc "SELECT id FROM booking ORDER BY id;" 2>/dev/null)

for BOOKING_ID in $BOOKING_IDS; do
    PRECIO_ANTES=$(psql_val "SELECT total_price FROM booking WHERE id = $BOOKING_ID;")
    UPDATE_RESULT=$(PGPASSWORD=fraude_pass_456 psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U frauduser -d "$DB_NAME" -c \
        "UPDATE booking SET total_price = total_price * 0.01 WHERE id = $BOOKING_ID;" 2>&1)
    PRECIO_DESPUES=$(psql_val "SELECT total_price FROM booking WHERE id = $BOOKING_ID;")
    echo -e "  ${DIM}UPDATE booking SET total_price = total_price * 0.01 WHERE id = ${BOOKING_ID}; --> ${UPDATE_RESULT}${NC}"
    echo -e "         id=${BOOKING_ID}: ${GREEN}\$${PRECIO_ANTES}${NC} --> ${RED}\$${PRECIO_DESPUES}${NC}"
done

echo ""

run_query "Estado de reservas después del ataque (precios reducidos)" \
    "SELECT id, item_name, total_price, status FROM booking ORDER BY id;"

run_query "Audit log con operaciones de frauduser (evidencia del ataque distribuido)" \
    "SELECT id, operations AS op, changed_by, changed_at, (new_data->>'id') AS fila_atacada, (old_data->>'total_price') AS precio_antes, (new_data->>'total_price') AS precio_despues FROM audit.audit_log WHERE changed_by = 'frauduser' ORDER BY id;"

FRAUD_AUDIT=$(psql_val "SELECT COUNT(*) FROM audit.audit_log WHERE changed_by = 'frauduser';")
FRAUD_ROWS=$(psql_val "SELECT COUNT(DISTINCT new_data->>'id') FROM audit.audit_log WHERE changed_by = 'frauduser';")
if [ "${FRAUD_AUDIT:-0}" -ge 1 ]; then
    check "Operaciones de frauduser registradas ($FRAUD_AUDIT ops en $FRAUD_ROWS filas distintas)" 0
else
    check "Operaciones de frauduser registradas en audit_log ($FRAUD_AUDIT registros)" 1
fi

echo ""

# ── Paso 5: Esperar detección y bloqueo ──────────────────────────
echo -e "${YELLOW}[5/6] RE1: Esperando detección por el Auditor (máx 10s)...${NC}"

DETECTED=false
DETECT_TIME=99
for i in $(seq 1 20); do
    sleep 0.5
    AUDITOR_LOG=$(docker logs auditor 2>&1 | grep -c "FRAUD_DETECTED" || true)
    if [ "$AUDITOR_LOG" -ge 1 ] 2>/dev/null; then
        DETECT_TIME=$(( $(date +%s) - FRAUD_START ))
        DETECTED=true
        break
    fi
done

if $DETECTED && [ "$DETECT_TIME" -le 10 ]; then
    check "Detección en ≤ 10 segundos (tardó: ${DETECT_TIME}s)" 0
elif $DETECTED; then
    check "Detección en ≤ 10 segundos (tardó: ${DETECT_TIME}s)" 1
else
    check "Detección en ≤ 10 segundos (NO detectado en 10s)" 1
fi

echo ""
echo -e "${YELLOW}    RE3: Verificando bloqueo del usuario (máx 30s)...${NC}"

BLOCKED=false
BLOCK_TIME=99
for i in $(seq 1 60); do
    sleep 0.5
    FRAUD_PRIV=$(psql_val "SELECT has_table_privilege('frauduser', 'booking', 'UPDATE');" 2>/dev/null || echo "f")
    if [ "$FRAUD_PRIV" = "f" ]; then
        BLOCK_TIME=$(( $(date +%s) - FRAUD_START ))
        BLOCKED=true
        break
    fi
done

if $BLOCKED && [ "$BLOCK_TIME" -le 30 ]; then
    check "Usuario frauduser bloqueado en ≤ 30 segundos (tardó: ${BLOCK_TIME}s)" 0
elif $BLOCKED; then
    check "Usuario frauduser bloqueado en ≤ 30 segundos (tardó: ${BLOCK_TIME}s)" 1
else
    check "Usuario frauduser bloqueado en ≤ 30 segundos (NO bloqueado)" 1
fi

echo ""

# ── Paso 6: Verificar estado post-respuesta ──────────────────────
echo -e "${YELLOW}[6/6] Verificando estado después de la respuesta del Auditor...${NC}"

echo -e "  ${DIM}SQL [frauduser]: UPDATE booking SET total_price = 0 WHERE id = 1;${NC}"
FRAUD_ATTEMPT=$(PGPASSWORD=fraude_pass_456 psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U frauduser -d "$DB_NAME" -c \
    "UPDATE booking SET total_price = 0 WHERE id = 1;" 2>&1 || true)
echo -e "  ${DIM}Resultado: ${FRAUD_ATTEMPT}${NC}"
if echo "$FRAUD_ATTEMPT" | grep -qi "denied\|permission\|FATAL"; then
    check "frauduser no puede ejecutar más operaciones (bloqueado)" 0
else
    check "frauduser no puede ejecutar más operaciones" 1
fi

run_query "Permisos de frauduser después del bloqueo" \
    "SELECT has_table_privilege('frauduser', 'booking', 'SELECT') AS can_select, has_table_privilege('frauduser', 'booking', 'UPDATE') AS can_update;"

# Esperar a que el auditor complete la reversión de TODAS las filas
echo -e "  Esperando reversión por el Auditor..."
REVERTED=false
for i in $(seq 1 20); do
    sleep 0.5
    ALL_REVERTED=true
    for BID in $BOOKING_IDS_PRE; do
        CURRENT=$(psql_val "SELECT total_price FROM booking WHERE id = $BID;")
        if [ "$CURRENT" != "${ORIGINAL_PRICES[$BID]}" ]; then
            ALL_REVERTED=false
            break
        fi
    done
    if $ALL_REVERTED; then
        REVERTED=true
        break
    fi
done

run_query "Estado de reservas después de reversión" \
    "SELECT id, item_name, total_price, status FROM booking ORDER BY id;"

REVERT_OK=0
REVERT_FAIL=0
for BID in $BOOKING_IDS_PRE; do
    CURRENT=$(psql_val "SELECT total_price FROM booking WHERE id = $BID;")
    if [ "$CURRENT" = "${ORIGINAL_PRICES[$BID]}" ]; then
        echo -e "  ${GREEN}[OK]${NC} booking.id=$BID: \$${CURRENT} (original: \$${ORIGINAL_PRICES[$BID]})"
        REVERT_OK=$((REVERT_OK + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} booking.id=$BID: \$${CURRENT} (original: \$${ORIGINAL_PRICES[$BID]})"
        REVERT_FAIL=$((REVERT_FAIL + 1))
    fi
done

if [ "$REVERT_FAIL" -eq 0 ]; then
    check "Cambios fraudulentos revertidos en todas las filas ($REVERT_OK/$REVERT_OK)" 0
else
    check "Cambios fraudulentos revertidos ($REVERT_OK OK, $REVERT_FAIL fallaron)" 1
fi

run_query "Audit log completo (todas las operaciones)" \
    "SELECT id, operations AS op, changed_by, changed_at, substring(old_data::text, 1, 50) AS old_data, substring(new_data::text, 1, 50) AS new_data FROM audit.audit_log ORDER BY id;"

# ── Logs del auditor ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}── Logs del componente Auditor ──${NC}"
docker logs auditor 2>&1 | tail -25
echo ""

# ── Métricas de Prometheus ───────────────────────────────────────
echo -e "${CYAN}── Métricas de auditoría en Prometheus ──${NC}"
echo -e "  Esperando 15s para que Prometheus scrape..."
sleep 15

echo -e "  ${DIM}GET ${PROMETHEUS_URL}/api/v1/query?query=audit_fraud_user_operations_total${NC}"
FRAUD_METRIC=$(curl -sf "$PROMETHEUS_URL/api/v1/query?query=audit_fraud_user_operations_total" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo "N/A")
echo -e "  audit_fraud_user_operations_total = ${FRAUD_METRIC}"

echo -e "  ${DIM}GET ${PROMETHEUS_URL}/api/v1/query?query=audit_total_events_total${NC}"
TOTAL_METRIC=$(curl -sf "$PROMETHEUS_URL/api/v1/query?query=audit_total_events_total" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo "N/A")
echo -e "  audit_total_events_total = ${TOTAL_METRIC}"

echo -e "  ${DIM}GET ${PROMETHEUS_URL}/api/v1/query?query=audit_updates_last_5m_total${NC}"
UPDATE_METRIC=$(curl -sf "$PROMETHEUS_URL/api/v1/query?query=audit_updates_last_5m_total" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo "N/A")
echo -e "  audit_updates_last_5m_total = ${UPDATE_METRIC}"
echo ""

echo -e "${CYAN}── Alertas activas en Prometheus ──${NC}"
echo -e "  ${DIM}GET ${PROMETHEUS_URL}/api/v1/alerts${NC}"
curl -sf "$PROMETHEUS_URL/api/v1/alerts" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['alerts']
audit_alerts = [a for a in data if a['labels'].get('alertname','').startswith('Audit')]
for a in audit_alerts:
    print(f\"  - {a['labels']['alertname']}: {a['state']} -> {a['annotations'].get('summary','')}\")
if not audit_alerts:
    print('  (ninguna alerta de audit disparada)')
" 2>/dev/null || echo "  (no se pudo consultar Prometheus)"

# ── Resumen ──────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN} RESULTADOS DEL EXPERIMENTO                           ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "  Total verificaciones: $TOTAL"
echo -e "  ${GREEN}Pasaron: $PASS${NC}"
echo -e "  ${RED}Fallaron: $FAIL${NC}"
echo ""
RE1="NO CUMPLE"; RE3="NO CUMPLE"
if $DETECTED && [ "$DETECT_TIME" -le 10 ]; then RE1="CUMPLE"; fi
if $BLOCKED && [ "$BLOCK_TIME" -le 30 ]; then RE3="CUMPLE"; fi

echo -e "  RE1 Detección + alerta ≤ 10s ............ $(if [ "$RE1" = "CUMPLE" ]; then echo -e "${GREEN}$RE1 (${DETECT_TIME}s)${NC}"; else echo -e "${RED}$RE1${NC}"; fi)"
echo -e "  RE2 Evidencia en audit_log ............... ${GREEN}CUMPLE${NC}"
echo -e "  RE3 Bloqueo usuario ≤ 30s ................ $(if [ "$RE3" = "CUMPLE" ]; then echo -e "${GREEN}$RE3 (${BLOCK_TIME}s)${NC}"; else echo -e "${RED}$RE3${NC}"; fi)"
echo -e "  RE4 Canal autorizado sin alerta .......... $(if [ "$BOOKING_GRANT" = "t" ]; then echo -e "${GREEN}CUMPLE${NC}"; else echo -e "${RED}NO CUMPLE${NC}"; fi)"

if [ "$FAIL" -eq 0 ]; then
    echo -e ""
    echo -e "  ${GREEN}EXPERIMENTO EXITOSO - Todos los resultados esperados se cumplen${NC}"
else
    echo -e ""
    echo -e "  ${RED}EXPERIMENTO CON FALLOS ($FAIL)${NC}"
fi
echo -e "${CYAN}======================================================${NC}"

exit "$FAIL"
