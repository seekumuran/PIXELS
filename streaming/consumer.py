"""
consumer.py

The "consumer" in the streaming layer. Reads order events off the Kafka/
Redpanda topic and writes each one into Postgres. This is the bridge R
can't do natively — R has no solid native Kafka client, so this small
Python consumer does the Kafka -> Postgres hop, and the R/Shiny app reads
from Postgres as its "subscriber."

Usage:
    pip install -r requirements.txt
    python consumer.py
"""

import json

import psycopg2
from kafka import KafkaConsumer

TOPIC = "orders_raw"
BOOTSTRAP_SERVERS = ["localhost:9092"]

PG_CONFIG = dict(
    host="localhost",
    port=5432,
    dbname="dynaroute",
    user="dynaroute",
    password="dynaroute",
)

INSERT_SQL = """
    INSERT INTO orders (outlet_id, sim_hour, queue_length)
    VALUES (%s, %s, %s)
"""


def run():
    consumer = KafkaConsumer(
        TOPIC,
        bootstrap_servers=BOOTSTRAP_SERVERS,
        value_deserializer=lambda v: json.loads(v.decode("utf-8")),
        auto_offset_reset="latest",
        group_id="dynaroute-consumer",
    )

    conn = psycopg2.connect(**PG_CONFIG)
    conn.autocommit = True
    cur = conn.cursor()

    print(f"Consumer started. Listening on topic: {TOPIC}. Writing to Postgres 'orders' table.")

    for message in consumer:
        order = message.value
        cur.execute(INSERT_SQL, (order["outlet_id"], order["sim_hour"], order["queue_length"]))
        print(f"wrote to postgres <- {order}")


if __name__ == "__main__":
    run()
