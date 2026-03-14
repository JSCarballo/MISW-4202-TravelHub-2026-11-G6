-- Base de datos principal
SELECT 'CREATE DATABASE booking_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'booking_db')\gexec

-- Conectar a booking_db una sola vez
\c booking_db

-- Tabla de reservas
CREATE TABLE IF NOT EXISTS booking (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL,
    sku         VARCHAR(20) NOT NULL,
    item_name   VARCHAR(100) NOT NULL,
    quantity    INTEGER NOT NULL DEFAULT 1,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'confirmed', 'cancelled')),
    total_price NUMERIC(10, 2) NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Datos de ejemplo
INSERT INTO booking (user_id, sku, item_name, quantity, status, total_price) VALUES
    (1, 'HTL-001', 'Hotel Cartagena',        1, 'confirmed', 350000.00),
    (2, 'FLT-002', 'Vuelo Bogota-Medellin',  2, 'pending',    180000.00),
    (3, 'CAR-003', 'Renta auto compacta',    1, 'cancelled',   95000.00),
    (1, 'FLT-002', 'Vuelo Bogota-Medellin',  1, 'confirmed',   90000.00);

-- Usuario para el microservicio de reservas (acceso legítimo)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'bookinguser') THEN
        CREATE USER bookinguser WITH PASSWORD 'reservas_pass_123';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE booking_db TO bookinguser;
GRANT USAGE ON SCHEMA public TO bookinguser;
REVOKE ALL PRIVILEGES ON TABLE booking FROM bookinguser;
GRANT SELECT, INSERT, UPDATE ON TABLE booking TO bookinguser;
REVOKE ALL PRIVILEGES ON SEQUENCE booking_id_seq FROM bookinguser;
GRANT USAGE, SELECT ON SEQUENCE booking_id_seq TO bookinguser;

-- Usuario fraudulento (acceso solo actualización para simulación de fraude)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'frauduser') THEN
        CREATE USER frauduser WITH PASSWORD 'fraude_pass_456';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE booking_db TO frauduser;
GRANT USAGE ON SCHEMA public TO frauduser;
REVOKE ALL PRIVILEGES ON TABLE booking FROM frauduser;
GRANT UPDATE ON TABLE booking TO frauduser;
GRANT SELECT (id) ON TABLE booking TO frauduser;
