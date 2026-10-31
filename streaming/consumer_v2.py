"""
consumer_v2.py

Reads events from the "orders_v2" Kafka topic and writes them into a
Postgres table called `live_orders`. Creates that table itself on first
connect (CREATE TABLE IF NOT EXISTS), so this works against the SAME
Postgres container as the original streaming layer -- no changes needed to
docker-compose.yml or init.sql.

R/09_live_queue.R reads from this exact table.

Usage:
    pip install -r requirements.txt
    python consumer_v2.py
"""

import json

import psycopg2
from kafka import KafkaConsumer

TOPIC = "orders_v2"
BOOTSTRAP_SERVERS = ["localhost:9092"]

PG_CONFIG = dict(
    host="localhost", port=5432,
    dbname="dynaroute", user="dynaroute", password="dynaroute",
)

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS live_orders (
    id              SERIAL PRIMARY KEY,
    order_id        TEXT,
    event_timestamp TIMESTAMPTZ,
    outlet_id       TEXT NOT NULL,
    customer_lat    DOUBLE PRECISION,
    customer_lon    DOUBLE PRECISION,
    sim_hour        INT NOT NULL,
    queue_length    INT,
    prep_time       DOUBLE PRECISION,
    weather         TEXT,
    traffic_level   TEXT,
    is_historical   BOOLEAN,
    received_at     TIMESTAMPTZ DEFAULT now()
);
"""

INSERT_SQL = """
INSERT INTO live_orders
    (order_id, event_timestamp, outlet_id, customer_lat, customer_lon,
     sim_hour, queue_length, prep_time, weather, traffic_level, is_historical)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
"""


def run():
    conn = psycopg2.connect(**PG_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(CREATE_TABLE_SQL)
    print("consumer_v2: 'live_orders' table ready.")

    consumer = KafkaConsumer(
        TOPIC,
        bootstrap_servers=BOOTSTRAP_SERVERS,
        value_deserializer=lambda v: json.loads(v.decode("utf-8")),
        auto_offset_reset="earliest",
        group_id="dynaroute-consumer-v2",
    )

    print(f"consumer_v2: listening on topic '{TOPIC}'...")
    for message in consumer:
        e = message.value
        cur.execute(INSERT_SQL, (
            e["order_id"], e["timestamp"], e["outlet_id"],
            e["customer_lat"], e["customer_lon"], e["hour"],
            e["queue_length"], e["prep_time"], e["weather"],
            e["traffic_level"], e["is_historical"],
        ))
        print(f"wrote -> {e['outlet_id']} @ sim hour {e['hour']:02d}")


if __name__ == "__main__":
    run()
