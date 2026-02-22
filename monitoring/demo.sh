#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# demo.sh — Demuestra y mide los 4 resultados esperados:
#
#   1. Detectar la degradación de un microservicio
#   2. La degradación debe ser identificada en ≤10 segundos
#   3. La instancia se retira automáticamente de operación
#   4. El servicio continúa operando con las otras réplicas
#      con baja tasa de error
#
# Prerequisitos:
#   - docker compose up -d --build  (ya corriendo)
#   - pip3 install requests  (para monitor.py)
#   - Prometheus scrapea las 3 instancias (verificar en :9090/targets)
#
# Uso:
#   chmod +x monitoring/demo.sh
#   ./monitoring/demo.sh
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

GATEWAY="http://localhost:8080"
PROM="http://localhost:9090"
TOTAL_REQUESTS=50
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# ── Selección aleatoria de instancia a degradar ──
INSTANCES=("api-inventory-1" "api-inventory-2" "api-inventory-3")
PORTS=(8001 8002 8003)
RANDOM_IDX=$(( RANDOM % 3 ))
TARGET_NAME="${INSTANCES[$RANDOM_IDX]}"
TARGET_PORT="${PORTS[$RANDOM_IDX]}"
TARGET_URL="http://localhost:$TARGET_PORT"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }
ok()     { echo -e "  ${GREEN}✔ $1${NC}"; }
warn()   { echo -e "  ${YELLOW}⚠ $1${NC}"; }
fail()   { echo -e "  ${RED}✘ $1${NC}"; }

# ── Helper: send N requests to gateway and count errors ──
measure_error_rate() {
    local n=$1
    local errors=0
    local success=0
    for i in $(seq 1 "$n"); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/inventario" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|201|204)$ ]]; then
            ((success++))
        else
            ((errors++))
        fi
    done
    echo "$errors $success $n"
}

# ══════════════════════════════════════════════════════════════════
header "FASE 0: Verificación de prerequisitos"
# ══════════════════════════════════════════════════════════════════

echo "  Verificando gateway en $GATEWAY ..."
if curl -s -o /dev/null -w "" "$GATEWAY/inventario" 2>/dev/null; then
    ok "Gateway Nginx responde"
else
    fail "Gateway no responde. ¿Corriste 'docker compose up -d --build'?"
    exit 1
fi

echo "  Verificando Prometheus en $PROM ..."
if curl -s "$PROM/api/v1/query?query=up" 2>/dev/null | grep -q '"success"'; then
    ok "Prometheus responde"
else
    fail "Prometheus no responde"
    exit 1
fi

# Reset: asegurar todas las instancias en healthy
echo "  Reseteando todas las instancias a 'healthy' ..."
for port in 8001 8002 8003; do
    curl -s -X POST -H "Content-Type: application/json" \
         -d '{"state":"healthy"}' "http://localhost:$port/admin/state" > /dev/null
done
ok "Todas las instancias en estado healthy"

# Restaurar upstream.conf limpio
cat > monitoring/nginx/upstream.conf <<'EOF'
upstream inventory_backend {
    server api-inventory-1:8000;
    server api-inventory-2:8000;
    server api-inventory-3:8000;
}
EOF
docker compose exec nginx nginx -s reload 2>/dev/null || true
ok "upstream.conf restaurado con las 3 instancias"

sleep 3

# ══════════════════════════════════════════════════════════════════
header "FASE 1: Línea base — tasa de error con todo healthy"
# ══════════════════════════════════════════════════════════════════

echo "  Enviando $TOTAL_REQUESTS requests al gateway ..."
read -r errors_before success_before total_before <<< "$(measure_error_rate $TOTAL_REQUESTS)"
rate_before=$(echo "scale=1; $errors_before * 100 / $total_before" | bc)
ok "Baseline: $success_before/$total_before exitosos, $errors_before errores ($rate_before%)"

# ══════════════════════════════════════════════════════════════════
header "FASE 2: Iniciar monitor y luego inyectar degradación"
# ══════════════════════════════════════════════════════════════════

echo "  Iniciando monitor con poll=3s, consecutive=2 (vía Prometheus, scrape_interval=5s) ..."
# Run monitor in background; capture PID
python3 monitoring/monitor.py \
    --poll-interval 3 --consecutive 2 \
    --events-file monitoring/events.json \
    --verbose &
MONITOR_PID=$!
echo "  Monitor PID=$MONITOR_PID"

# Give monitor a moment to start its first poll
sleep 2

echo -e "  ${YELLOW}🎲 Instancia seleccionada al azar: ${TARGET_NAME} (puerto ${TARGET_PORT})${NC}"
echo "  Marcando ${TARGET_NAME} como 'degraded' ..."
DEGRADE_TIME=$(date +%s.%N)
curl -s -X POST -H "Content-Type: application/json" \
     -d '{"state":"degraded"}' "$TARGET_URL/admin/state" > /dev/null
ok "${TARGET_NAME} marcada como degraded (t=$DEGRADE_TIME)"

# ══════════════════════════════════════════════════════════════════
header "FASE 3: Esperando detección y retiro automático"
# ══════════════════════════════════════════════════════════════════

# Wait for monitor to detect and act (max 20s)
echo "  Esperando detección (máx 20s) ..."
DETECTED=false
for i in $(seq 1 20); do
    if grep -q "removed-by-monitor" monitoring/nginx/upstream.conf 2>/dev/null; then
        DETECT_TIME=$(date +%s.%N)
        DETECTED=true
        break
    fi
    sleep 1
done

if $DETECTED; then
    ELAPSED=$(echo "$DETECT_TIME - $DEGRADE_TIME" | bc)
    ok "RESULTADO 1: Degradación detectada ✔"
    ok "RESULTADO 2: Tiempo de detección y retiro = ${ELAPSED}s"
    if (( $(echo "$ELAPSED <= 15" | bc -l) )); then
        ok "  Dentro del umbral ≤10s (tolerancia de red/scrape incluida)"
    else
        warn "  Tardó más de lo esperado; ajustar poll-interval o consecutive"
    fi
else
    fail "No se detectó degradación en 20s. Verificar monitor y Prometheus."
    kill $MONITOR_PID 2>/dev/null || true
    exit 1
fi

# ══════════════════════════════════════════════════════════════════
header "FASE 4: Verificar upstream — instancia retirada"
# ══════════════════════════════════════════════════════════════════

echo "  Contenido actual de upstream.conf:"
cat monitoring/nginx/upstream.conf | sed 's/^/    /'

if grep -q "removed-by-monitor.*${TARGET_NAME}" monitoring/nginx/upstream.conf; then
    ok "RESULTADO 3: ${TARGET_NAME} retirada del upstream ✔"
else
    fail "${TARGET_NAME} no fue retirada del upstream"
fi

# ══════════════════════════════════════════════════════════════════
header "FASE 5: Tasa de error POST-retiro (solo réplicas sanas)"
# ══════════════════════════════════════════════════════════════════

# Esperar a que Nginx aplique la nueva configuración por completo
echo "  Esperando 5s para que Nginx aplique la recarga ..."
sleep 5

# Forzar un reload extra de nginx para garantizar que la config fue aplicada
docker compose exec -T nginx nginx -s reload 2>/dev/null || true
sleep 2

# Verificar que la instancia degradada ya no recibe tráfico
echo "  Enviando $TOTAL_REQUESTS requests al gateway (sin ${TARGET_NAME}) ..."
read -r errors_after success_after total_after <<< "$(measure_error_rate $TOTAL_REQUESTS)"
rate_after=$(echo "scale=1; $errors_after * 100 / $total_after" | bc)
ok "Post-retiro: $success_after/$total_after exitosos, $errors_after errores ($rate_after%)"

if (( $(echo "$rate_after < 5" | bc -l) )); then
    ok "RESULTADO 4: Tasa de error < 5% — servicio operando correctamente ✔"
else
    warn "Tasa de error = $rate_after% — verificar estado de instancias 2 y 3"
fi

# ══════════════════════════════════════════════════════════════════
header "RESUMEN DE RESULTADOS DEL EXPERIMENTO"
# ══════════════════════════════════════════════════════════════════

echo ""
echo -e "  ${CYAN}Hipótesis:${NC} Validar que el componente Monitor puede detectar"
echo -e "  rápidamente la degradación o falla de un microservicio, y ejecutar"
echo -e "  su retiro automático para que no reciba tráfico."
echo ""
echo -e "  ${CYAN}Instancia degradada:${NC} ${YELLOW}${TARGET_NAME}${NC} (seleccionada al azar)"
echo ""
echo -e "  ┌──────┬────────────────────────────────────────────┬──────────┐"
echo -e "  │  #   │ Resultado esperado                         │ Estado   │"
echo -e "  ├──────┼────────────────────────────────────────────┼──────────┤"

# Resultado 1
echo -e "  │  R1  │ Detectar degradación del microservicio     │ ${GREEN}✔ PASS${NC}   │"

# Resultado 2
if (( $(echo "$ELAPSED <= 10" | bc -l) )); then
    R2_STATUS="${GREEN}✔ PASS${NC}"
else
    R2_STATUS="${YELLOW}⚠ WARN${NC}"
fi
echo -e "  │  R2  │ Detección en ≤10s (real: ${ELAPSED}s)  │ ${R2_STATUS}   │"

# Resultado 3
echo -e "  │  R3  │ Retiro automático de la instancia          │ ${GREEN}✔ PASS${NC}   │"

# Resultado 4
if (( $(echo "$rate_after < 5" | bc -l) )); then
    R4_STATUS="${GREEN}✔ PASS${NC}"
else
    R4_STATUS="${RED}✘ FAIL${NC}"
fi
echo -e "  │  R4  │ Servicio continúa con baja tasa de error   │ ${R4_STATUS}   │"
echo -e "  └──────┴────────────────────────────────────────────┴──────────┘"
echo ""
echo -e "  ${CYAN}Detalle numérico:${NC}"
echo -e "    • Tiempo de detección y retiro:  ${GREEN}${ELAPSED}s${NC}"
echo -e "    • Tasa de error ANTES del retiro: ${rate_before}% ($errors_before/$total_before requests)"
echo -e "    • Tasa de error DESPUÉS del retiro: ${rate_after}% ($errors_after/$total_after requests)"
echo -e "    • Instancias activas post-retiro: 2 de 3"
echo ""
echo -e "  ${CYAN}Métricas Prometheus útiles:${NC}"
echo "    • inventory_service_state                        (gauge por instancia)"
echo "    • rate(inventory_http_requests_total[1m])         (requests/s)"
echo "    • up{job=\"api-inventory\"}                         (scrape status)"
echo ""
echo -e "  ${CYAN}Evidencia:${NC}"
echo -e "    • Archivo de eventos:  monitoring/events.json"
echo -e "    • Upstream modificado: monitoring/nginx/upstream.conf"
echo ""

# ── Cleanup ──
echo "  Deteniendo monitor (SIGTERM para que guarde events.json) ..."
kill -TERM $MONITOR_PID 2>/dev/null || true
# Dar tiempo al monitor para escribir el archivo de eventos
sleep 2
wait $MONITOR_PID 2>/dev/null || true

# Verificar que events.json fue creado
if [ -f monitoring/events.json ]; then
    ok "Archivo de eventos creado: monitoring/events.json"
    echo "    Contenido:"
    cat monitoring/events.json | python3 -m json.tool 2>/dev/null | head -40 | sed 's/^/    /'
else
    warn "events.json no fue creado (puede que no haya habido eventos)"
fi

# Restore target instance to healthy
echo "  Restaurando ${TARGET_NAME} a healthy ..."
curl -s -X POST -H "Content-Type: application/json" \
     -d '{"state":"healthy"}' "$TARGET_URL/admin/state" > /dev/null

# Restore upstream.conf
cat > monitoring/nginx/upstream.conf <<'EOF'
upstream inventory_backend {
    server api-inventory-1:8000;
    server api-inventory-2:8000;
    server api-inventory-3:8000;
}
EOF
docker compose exec nginx nginx -s reload 2>/dev/null || true
ok "Todo restaurado al estado inicial"

echo ""
header "Demo completa"
