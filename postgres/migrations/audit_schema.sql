CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE audit.audit_log(
    id BIGSERIAL PRIMARY KEY,
    schema_name VARCHAR(30) NOT NULL,
    table_name VARCHAR(63) NOT NULL,
    operations CHAR(1) NOT NULL CHECK (operations IN ('I','U','D')),
    old_data JSONB,
    new_data JSONB,
    changed_by VARCHAR(63) NOT NULL DEFAULT current_user,
    changed_at TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_audit_log_table ON audit.audit_log(schema_name, table_name);
CREATE INDEX idx_audit_log_changed_at ON audit.audit_log(changed_at DESC);
CREATE INDEX idx_audit_log_changed_by ON audit.audit_log(changed_by);
CREATE INDEX idx_audit_log_operations ON audit.audit_log(operations);

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
        operations,
        old_data,
        new_data,
        changed_by,
        changed_at
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        op,
        old_row,
        new_row,
        current_user,
        clock_timestamp()
    );
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

CREATE TRIGGER audit_booking_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.booking
    FOR EACH ROW 
    EXECUTE FUNCTION audit.audit_trigger_function();

REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM bookinguser;
REVOKE INSERT, UPDATE, DELETE ON audit.audit_log FROM frauduser;
