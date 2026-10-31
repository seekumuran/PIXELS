-- init.sql
-- Runs automatically the first time the Postgres container starts.
-- One table: every simulated order the Kafka consumer writes lands here.
-- The R/Shiny app reads from this table as its "subscriber."

CREATE TABLE IF NOT EXISTS orders (
    id                SERIAL PRIMARY KEY,
    outlet_id         TEXT NOT NULL,
    sim_hour          INT NOT NULL,          -- compressed-clock hour of day (0-23)
    queue_length      INT NOT NULL,          -- queue length at that outlet when this order landed
    received_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_outlet_id ON orders (outlet_id);
CREATE INDEX IF NOT EXISTS idx_orders_received_at ON orders (received_at);
