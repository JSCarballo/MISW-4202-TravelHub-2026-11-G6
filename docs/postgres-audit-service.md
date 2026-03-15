# Servicio de Auditoría en PostgreSQL - TravelHub

Registro de quién, cuándo y qué cambios se realizan en las tablas críticas (ej. `booking`).

---

## 1. Objetivos

- **Trazabilidad**: Registrar cada cambio (INSERT, UPDATE, DELETE) en tablas sensibles.
- **Detección de fraude**: Soporte para análisis de patrones anómalos en las operaciones.
- **Recuperación**: Historial para análisis forense o rollback de datos.

---

## 2. Enfoque: Triggers + tabla de auditoría

Se usa **triggers + tabla de auditoría** para datos (DML) en `booking`. Es compatible con `postgres:16-alpine` y no requiere extensiones adicionales.

---

## 3. Esquema implementado

### 3.1 Tabla `audit.audit_log`

Se usa un esquema dedicado `audit` para separar las tablas de negocio de las de auditoría.

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | BIGSERIAL | PK del registro de auditoría |
| `schema_name` | VARCHAR(30) | Esquema de la tabla auditada (ej. `public`) |
| `table_name` | VARCHAR(63) | Nombre de la tabla (ej. `booking`) |
| `operations` | CHAR(1) | `I` = INSERT, `U` = UPDATE, `D` = DELETE |
| `old_data` | JSONB | Estado anterior (UPDATE/DELETE); NULL en INSERT |
| `new_data` | JSONB | Estado nuevo (INSERT/UPDATE); NULL en DELETE |
| `changed_by` | VARCHAR(63) | Usuario de PostgreSQL que ejecutó la operación |
| `changed_at` | TIMESTAMP | Momento de la operación |

### 3.2 SQL de creación

```sql
CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.audit_log(
    id BIGSERIAL PRIMARY KEY,
    schema_name VARCHAR(30) NOT NULL,
    table_name VARCHAR(63) NOT NULL,
    operations CHAR(1) NOT NULL CHECK (operations IN ('I','U','D')),
    old_data JSONB,
    new_data JSONB,
    changed_by VARCHAR(63) NOT NULL DEFAULT session_user,
    changed_at TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_audit_log_table ON audit.audit_log(schema_name, table_name);
CREATE INDEX idx_audit_log_changed_at ON audit.audit_log(changed_at DESC);
CREATE INDEX idx_audit_log_changed_by ON audit.audit_log(changed_by);
CREATE INDEX idx_audit_log_operations ON audit.audit_log(operations);
```

### 3.3 Función de auditoría

La función usa `SECURITY DEFINER` para escribir en `audit.audit_log` aunque el usuario que ejecuta la operación no tenga permisos sobre el esquema `audit`. Se usa `session_user` (no `current_user`) para capturar el usuario real de la conexión, ya que `current_user` dentro de `SECURITY DEFINER` retorna el dueño de la función.

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
        schema_name, table_name, operations,
        old_data, new_data, changed_by, changed_at
    ) VALUES (
        TG_TABLE_SCHEMA, TG_TABLE_NAME, op,
        old_row, new_row, session_user, clock_timestamp()
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;
```

### 3.4 Trigger

```sql
CREATE TRIGGER audit_booking_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.booking
    FOR EACH ROW
    EXECUTE FUNCTION audit.audit_trigger_function();
```

Para auditar otras tablas:

```sql
CREATE TRIGGER audit_<tabla>_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.<tabla>
    FOR EACH ROW
    EXECUTE FUNCTION audit.audit_trigger_function();
```

### 3.5 Permisos

Los usuarios de aplicación no pueden modificar la tabla de auditoría directamente. El trigger escribe como `SECURITY DEFINER` (con el rol del dueño de la función).

```sql
REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM bookinguser;
REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM frauduser;
```

---

## 4. Consultas útiles

### Historial de un booking por ID

```sql
SELECT id, table_name, operations, changed_by, changed_at, old_data, new_data
FROM audit.audit_log
WHERE (old_data->>'id')::int = 1 OR (new_data->>'id')::int = 1
ORDER BY changed_at;
```

### Operaciones de un usuario

```sql
SELECT id, table_name, operations, changed_at, old_data, new_data
FROM audit.audit_log
WHERE changed_by = 'frauduser'
ORDER BY changed_at DESC;
```

### Cambios en una ventana de tiempo

```sql
SELECT id, table_name, operations, changed_by, changed_at,
       old_data->>'total_price' AS precio_antes,
       new_data->>'total_price' AS precio_despues
FROM audit.audit_log
WHERE operations = 'U'
  AND changed_at > NOW() - INTERVAL '30 seconds'
ORDER BY changed_at;
```

---

## 5. Integración en el proyecto

El esquema de auditoría se ejecuta automáticamente al levantar los contenedores. En `docker-compose.yml`, los scripts se montan en orden:

```yaml
volumes:
  - ./postgres/init.sql:/docker-entrypoint-initdb.d/01_init.sql
  - ./postgres/migrations/audit_schema.sql:/docker-entrypoint-initdb.d/02_audit_schema.sql
```

PostgreSQL ejecuta los scripts en `/docker-entrypoint-initdb.d/` en orden alfabético, solo cuando el volumen de datos está vacío (primera ejecución o después de `docker compose down -v`).

---

## 6. Nota sobre `session_user` vs `current_user`

En funciones con `SECURITY DEFINER`, `current_user` retorna el dueño de la función (ej. `admin`), no el usuario que ejecutó la operación original. Por eso se usa `session_user`, que siempre refleja el usuario de la conexión activa (ej. `bookinguser`, `frauduser`).

---

## 7. Usuarios de base de datos

| Usuario | Contraseña | Permisos | Uso |
|---------|-----------|----------|-----|
| `admin` | `adminTravelHub` | Superusuario | Dueño de la BD, auditor |
| `bookinguser` | `reservas_pass_123` | SELECT, INSERT, UPDATE, DELETE | Microservicio de reservas |
| `frauduser` | `fraude_pass_456` | SELECT, UPDATE | Simulación de atacante |
