# Guía: Implementación del Servicio de Auditoría en PostgreSQL

Este documento describe cómo implementar un servicio de auditoría en PostgreSQL para el proyecto TravelHub, permitiendo registrar quién, cuándo y qué cambios se realizan en las tablas críticas (por ejemplo, `booking`).

---

## 1. Objetivos del servicio de auditoría

- **Trazabilidad**: Registrar cada cambio (INSERT, UPDATE, DELETE) en tablas sensibles.
- **Cumplimiento**: Soporte para auditorías de seguridad y detección de fraude (ej. uso del usuario `frauduser`).
- **Recuperación**: Historial para análisis forense o rollback de datos.
- **Transparencia**: Saber qué usuario de base de datos realizó cada operación y en qué momento.

---

## 2. Enfoques posibles

| Enfoque | Ventajas | Desventajas |
|--------|----------|-------------|
| **Triggers + tabla de auditoría** | Sin extensiones, portable, control total del esquema | Hay que escribir triggers por tabla |
| **Extensión pgaudit** | Auditoría a nivel de sentencias/objetos, muy completa | Requiere permisos de superusuario, más orientada a DDL y sesiones |
| **Auditoría en aplicación** | Lógica en el código del microservicio | No captura cambios directos por SQL ni por otros clientes |

**Recomendación para TravelHub**: usar **triggers + tabla de auditoría** para datos (DML) en `booking` y tablas similares. Es compatible con tu imagen `postgres:16-alpine` y no requiere extensiones adicionales.

---

## 3. Diseño del esquema de auditoría

### 3.1 Esquema dedicado (recomendado)

Se crea un esquema `audit` para no mezclar tablas de negocio con las de auditoría y facilitar permisos.

### 3.2 Tabla de auditoría genérica

Una sola tabla puede auditar varias tablas usando columnas que identifican la tabla y las filas afectadas:

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | BIGSERIAL | PK del registro de auditoría |
| `schema_name` | VARCHAR(63) | Esquema de la tabla auditada (ej. `public`) |
| `table_name` | VARCHAR(63) | Nombre de la tabla (ej. `booking`) |
| `operation` | CHAR(1) | `I` = INSERT, `U` = UPDATE, `D` = DELETE |
| `old_data` | JSONB | Estado anterior (UPDATE/DELETE); NULL en INSERT |
| `new_data` | JSONB | Estado nuevo (INSERT/UPDATE); NULL en DELETE |
| `changed_by` | VARCHAR(63) | Usuario de PostgreSQL que ejecutó la operación |
| `changed_at` | TIMESTAMPTZ | Momento de la operación (UTC) |
| `client_addr` | INET | IP del cliente (si está disponible) |
| `application_name` | VARCHAR(255) | `application_name` de la sesión (opcional) |

---

## 4. Implementación paso a paso

### 4.1 Crear el esquema y la tabla de auditoría

Ejecutar en `booking_db` (por ejemplo desde `psql` o desde un script de migración):

```sql
-- Esquema para objetos de auditoría
CREATE SCHEMA IF NOT EXISTS audit;

-- Tabla principal de auditoría
CREATE TABLE audit.audit_log (
    id             BIGSERIAL PRIMARY KEY,
    schema_name    VARCHAR(63) NOT NULL,
    table_name     VARCHAR(63) NOT NULL,
    operation      CHAR(1) NOT NULL CHECK (operation IN ('I', 'U', 'D')),
    old_data       JSONB,
    new_data       JSONB,
    changed_by     VARCHAR(63) NOT NULL DEFAULT current_user,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    client_addr    INET,
    application_name VARCHAR(255),
    CONSTRAINT valid_operation_data CHECK (
        (operation = 'I' AND old_data IS NULL AND new_data IS NOT NULL) OR
        (operation = 'U' AND old_data IS NOT NULL AND new_data IS NOT NULL) OR
        (operation = 'D' AND old_data IS NOT NULL AND new_data IS NULL)
    )
);

-- Índices para consultas frecuentes
CREATE INDEX idx_audit_log_table ON audit.audit_log (schema_name, table_name);
CREATE INDEX idx_audit_log_changed_at ON audit.audit_log (changed_at DESC);
CREATE INDEX idx_audit_log_changed_by ON audit.audit_log (changed_by);
CREATE INDEX idx_audit_log_operation ON audit.audit_log (operation);

-- Opcional: índice GIN para búsquedas en old_data/new_data
CREATE INDEX idx_audit_log_new_data ON audit.audit_log USING GIN (new_data);
CREATE INDEX idx_audit_log_old_data ON audit.audit_log USING GIN (old_data);

COMMENT ON TABLE audit.audit_log IS 'Registro de auditoría DML para tablas críticas';
```

### 4.2 Función genérica de auditoría (una para todas las tablas)

Esta función se invoca desde un trigger `AFTER INSERT OR UPDATE OR DELETE` y escribe en `audit.audit_log`:

```sql
CREATE OR REPLACE FUNCTION audit.audit_trigger_function()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, public
AS $$
DECLARE
    old_row JSONB;
    new_row JSONB;
    op CHAR(1);
BEGIN
    IF (TG_OP = 'DELETE') THEN
        old_row := to_jsonb(OLD);
        new_row := NULL;
        op := 'D';
    ELSIF (TG_OP = 'UPDATE') THEN
        old_row := to_jsonb(OLD);
        new_row := to_jsonb(NEW);
        op := 'U';
    ELSIF (TG_OP = 'INSERT') THEN
        old_row := NULL;
        new_row := to_jsonb(NEW);
        op := 'I';
    END IF;

    INSERT INTO audit.audit_log (
        schema_name,
        table_name,
        operation,
        old_data,
        new_data,
        changed_by,
        changed_at,
        client_addr,
        application_name
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        op,
        old_row,
        new_row,
        current_user,
        clock_timestamp(),
        inet_client_addr(),
        current_setting('application_name', true)
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;
```

- `SECURITY DEFINER`: el trigger escribe en `audit.audit_log` aunque el usuario que hace el INSERT/UPDATE/DELETE no tenga permisos sobre el esquema `audit`.
- `inet_client_addr()` puede ser NULL si la conexión no expone la IP (ej. algunas conexiones desde aplicaciones).

### 4.3 Asociar el trigger a la tabla `booking`

```sql
CREATE TRIGGER audit_booking_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.booking
    FOR EACH ROW
    EXECUTE FUNCTION audit.audit_trigger_function();
```

Para otras tablas que quieras auditar en el futuro:

```sql
CREATE TRIGGER audit_<tabla>_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.<tabla>
    FOR EACH ROW
    EXECUTE FUNCTION audit.audit_trigger_function();
```

### 4.4 Permisos

Los usuarios de aplicación (`bookinguser`, `frauduser`) no deben poder modificar ni borrar la tabla de auditoría. Solo el propietario (o un rol con permisos) debe poder escribir en ella (vía el trigger con `SECURITY DEFINER`). Opcionalmente, puedes dar solo lectura a un rol de auditoría:

```sql
-- Revocar escritura explícita para usuarios de app (el trigger sigue escribiendo como DEFINER)
REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM bookinguser;
REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM frauduser;

-- Opcional: rol de solo lectura para reportes
-- CREATE ROLE audit_reader;
-- GRANT USAGE ON SCHEMA audit TO audit_reader;
-- GRANT SELECT ON audit.audit_log TO audit_reader;
```

Asegúrate de que el rol que posee la función y la tabla (normalmente el usuario que creó la BD, ej. `admin`) sea el que ejecute el trigger; así `bookinguser` y `frauduser` no necesitan permisos sobre `audit.audit_log`.

---

## 5. Uso y consultas típicas

### 5.1 Historial de un booking por ID

```sql
SELECT id, table_name, operation, changed_by, changed_at,
       old_data, new_data
FROM audit.audit_log
WHERE schema_name = 'public' AND table_name = 'booking'
  AND (old_data->>'id')::int = 1
   OR (new_data->>'id')::int = 1
ORDER BY changed_at;
```

### 5.2 Todas las operaciones de un usuario (ej. detección de fraude)

```sql
SELECT id, table_name, operation, changed_at, old_data, new_data
FROM audit.audit_log
WHERE changed_by = 'frauduser'
ORDER BY changed_at DESC;
```

### 5.3 Cambios en una ventana de tiempo

```sql
SELECT id, table_name, operation, changed_by, changed_at,
       old_data->>'status' AS old_status,
       new_data->>'status' AS new_status
FROM audit.audit_log
WHERE table_name = 'booking'
  AND changed_at BETWEEN '2026-01-01' AND '2026-12-31'
ORDER BY changed_at;
```

### 5.4 Últimos N registros de auditoría

```sql
SELECT * FROM audit.audit_log
ORDER BY changed_at DESC
LIMIT 100;
```

---

## 6. Integración con el proyecto TravelHub

### 6.1 Script de migración recomendado

Crear un archivo separado para no tocar la inicialización base de datos existente, por ejemplo:

- **Archivo**: `postgres/migrations/001_audit_schema.sql`

Contenido: todo el SQL de las secciones 4.1, 4.2, 4.3 y 4.4.

Ejecución manual después de que la BD esté creada:

```bash
docker exec -i postgres psql -U admin -d booking_db < postgres/migrations/001_audit_schema.sql
```

O bien puedes añadir la creación del esquema, tabla, función y trigger al final de `postgres/init.sql` si prefieres que la auditoría exista desde el primer arranque. Ten en cuenta que `init.sql` solo se ejecuta si la carpeta de datos de PostgreSQL está vacía.

### 6.2 Orden recomendado en `init.sql`

Si decides integrar en `init.sql`, el orden debe ser:

1. Crear base de datos y conectar a `booking_db`.
2. Crear tablas de negocio (`booking`, etc.).
3. Crear usuarios y permisos de aplicación.
4. Crear esquema `audit`, tabla `audit.audit_log`, función `audit.audit_trigger_function()` y triggers.
5. Ajustar permisos (REVOKE en `audit.audit_log` para `bookinguser`/`frauduser`).

---

## 7. Consideraciones adicionales

### 7.1 Volumen y retención

- La tabla `audit.audit_log` puede crecer mucho. Plantéate una política de retención (por ejemplo, particionar por `changed_at` o borrar registros mayores a N meses).
- Los índices GIN en JSONB ayudan en consultas por contenido de `old_data`/`new_data`, pero aumentan el costo de escritura.

### 7.2 Rendimiento

- Los triggers se ejecutan en la misma transacción que el INSERT/UPDATE/DELETE. Si la auditoría crece mucho, considera escribir a una cola o a otra base y procesar de forma asíncrona (fuera del alcance de esta guía).
- Para la mayoría de cargas de TravelHub, una tabla de auditoría con triggers es suficiente.

### 7.3 Datos sensibles

- Si en `booking` (o en otras tablas) almacenas datos muy sensibles, valora ofuscar o no guardar ciertos campos en `old_data`/`new_data` dentro de la función del trigger (por ejemplo, no incluir contraseñas ni tokens en el JSONB).

### 7.4 Usuario de sesión vs. usuario de aplicación

- `current_user` refleja el usuario de PostgreSQL. En tu caso, `frauduser` y `bookinguser` quedarán registrados como `changed_by`.
- Si en el futuro quieres auditar “usuario de aplicación” (ej. ID de usuario de tu API), habría que pasarlo por una variable de sesión (ej. `SET LOCAL app.user_id = '123'`) y leerla en el trigger con `current_setting('app.user_id', true)` y guardarla en una columna adicional en `audit.audit_log`.

---

## 8. Resumen de pasos

1. Crear esquema `audit` y tabla `audit.audit_log` con índices.
2. Crear la función `audit.audit_trigger_function()`.
3. Crear el trigger `audit_booking_trigger` en `public.booking`.
4. Ajustar permisos (REVOKE de escritura en `audit.audit_log` para usuarios de app).
5. Ejecutar el script en `booking_db` (migración o `init.sql`).
6. Probar con INSERT/UPDATE/DELETE en `booking` y consultar `audit.audit_log`.

Con esto tendrás un servicio de auditoría PostgreSQL listo para usar en TravelHub, alineado con la detección de fraude (por ejemplo, monitoreando operaciones del usuario `frauduser`) y con trazabilidad completa de cambios en reservas.
