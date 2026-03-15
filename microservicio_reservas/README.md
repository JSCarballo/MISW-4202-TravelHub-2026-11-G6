# Escenario de Reservas/DB

Este microservicio materializa el canal autorizado de escritura para el experimento de Reservas. El acceso legítimo a la tabla `booking` debe hacerse únicamente por HTTP a `api-reservas`, usando `bookinguser` y `application_name=reservas-ms`.

## Endpoints

- `GET /health`: valida autenticación y conectividad a PostgreSQL.
- `POST /reservas`: crea una reserva con `status=pending`.
- `GET /reservas/<id>`: consulta una reserva puntual.
- `PATCH /reservas/<id>/status`: actualiza sólo `status` y `updated_at`.

## Script automatizado

1. Levantar los servicios necesarios:
   `docker compose up -d --build postgres api-reservas`
2. Ejecutar el flujo del experimento:
   `bash microservicio_reservas/run_db_experiment.sh`

El script valida salud, ejecuta escrituras legítimas por HTTP, dispara dos modificaciones directas con `frauduser` vía `psql` y deja una consulta final como `admin` para evidencia.

## Evidencia manual con pgAdmin

1. Abrir `http://localhost:5050/login?next=/` con `admin@admin.com` / `admin123`.
2. Registrar el servidor PostgreSQL usando host `postgres` si estás dentro de Docker Desktop, o `localhost` si conectas desde el host, puerto `5432`, base `booking_db`.
3. Conectarte como `admin` y capturar el estado inicial de `booking`:
   `SELECT id, user_id, sku, item_name, quantity, status, total_price, created_at, updated_at FROM booking ORDER BY id;`
4. Ejecutar un `POST /reservas` y un `PATCH /reservas/<id>/status` contra `api-reservas`; luego refrescar la consulta y capturar la nueva fila y el cambio de `updated_at`.
5. Abrir una herramienta SQL como `frauduser` y ejecutar:
   `UPDATE booking SET total_price = 999999.99 WHERE id = 2;`
   `UPDATE booking SET status = 'cancelled', updated_at = NOW() WHERE id = 1;`
6. Volver a `admin`, repetir la consulta de `booking` y capturar el before/after.
7. Cuando el Auditor esté integrado, repetir el `POST` y el `PATCH` anteriores y verificar en la ventana de observación del grupo que no aparezca alerta para el canal autorizado.

## Nota sobre permisos

`frauduser` no recibe lectura completa sobre la tabla. Sólo se deja el mínimo necesario para ejecutar `UPDATE ... WHERE id = ...` sobre la reserva objetivo y usar esos cambios como entrada del experimento.
