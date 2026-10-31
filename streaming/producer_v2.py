"""
producer_v2.py

Generates DynaRoute order events with a full schema and publishes them to a
NEW Kafka topic "orders_v2" -- this never collides with the original
producer.py / "orders_raw" topic, so both can coexist.

Two phases:
  1. HISTORICAL BURST -- quickly replays one full synthetic day (hour 0-23)
     with a realistic demand curve, so there's history in the topic/database
     before anything "live" happens.
  2. LIVE STREAM -- continues generating events in real time using a
     compressed clock (1 real minute = 1 simulated hour), so a demo shows
     the hostel curfew and demand shifts within a few minutes.

Usage:
    pip install -r requirements.txt
    python producer_v2.py
"""

import json
import os
import random
import time
import uuid
from datetime import datetime, timedelta

from kafka import KafkaProducer

TOPIC = "orders_v2"
BOOTSTRAP_SERVERS = ["localhost:9092"]

OUTLET_COUNT = int(os.environ.get("DYNAROUTE_OUTLET_COUNT", "12"))
OUTLETS = [f"O{i}" for i in range(1, OUTLET_COUNT + 1)]
HOSTEL_CURFEW_HOUR = 20
MINUTES_PER_SIM_HOUR = 1.0
BASELINE_RATE = 3  # orders per simulated hour
HOSTEL_RATE = 12   # additional orders per simulated hour during the spike

TRAFFIC_LEVELS = {
    range(0, 7): "Low", range(7, 11): "High", range(11, 17): "Moderate",
    range(17, 22): "Very High", range(22, 24): "Low",
}
WEATHER_CONDITIONS = ["Clear", "Cloudy", "Light Rain", "Heavy Rain"]
WEATHER_WEIGHTS = [0.55, 0.25, 0.15, 0.05]

# A couple of outlets are naturally busier; O2 is favoured during the hostel
# spike. The vectors scale with the configured outlet count.
BASE_OUTLET_WEIGHTS = [1 + (i % 3) * 0.25 for i in range(OUTLET_COUNT)]
HOSTEL_OUTLET_WEIGHTS = [4 if i == 1 else 1 for i in range(OUTLET_COUNT)]

producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)


def traffic_level_for_hour(hour):
    for hour_range, level in TRAFFIC_LEVELS.items():
        if hour in hour_range:
            return level
    return "Low"


def demand_lambda_for_hour(hour):
    """Piecewise rate shared with R/02_simulate_orders.R."""
    return BASELINE_RATE + (HOSTEL_RATE if 18 <= hour < HOSTEL_CURFEW_HOUR else 0)


def make_event(hour, is_historical, sim_timestamp):
    is_hostel_window = 18 <= hour < HOSTEL_CURFEW_HOUR
    weights = HOSTEL_OUTLET_WEIGHTS if is_hostel_window else BASE_OUTLET_WEIGHTS
    outlet_id = random.choices(OUTLETS, weights=weights)[0]

    weather = random.choices(WEATHER_CONDITIONS, weights=WEATHER_WEIGHTS)[0]
    traffic = traffic_level_for_hour(hour)

    return {
        "order_id": str(uuid.uuid4())[:8],
        "timestamp": sim_timestamp.isoformat(),
        "outlet_id": outlet_id,
        "customer_lat": round(13.0827 + random.uniform(-0.05, 0.05), 5),
        "customer_lon": round(80.2707 + random.uniform(-0.05, 0.05), 5),
        "hour": hour,
        "queue_length": random.randint(1, 15),
        "prep_time": round(random.uniform(5, 9), 1),
        "weather": weather,
        "traffic_level": traffic,
        "is_historical": is_historical,
    }


def run_historical_burst():
    """Publish one exact Poisson-realised day to seed the live dashboard."""
    print("Producer: sending historical Poisson burst (one synthetic day)...")
    now = datetime.utcnow()
    for hour in range(24):
        arrival_time = 0.0
        while True:
            arrival_time += random.expovariate(demand_lambda_for_hour(hour))
            if arrival_time >= 1:
                break
            sim_timestamp = now - timedelta(hours=(24 - hour - arrival_time))
            event = make_event(hour, is_historical=True, sim_timestamp=sim_timestamp)
            producer.send(TOPIC, value=event)
    producer.flush()
    print("Historical burst sent.")


def run_live_stream():
    print("Producer: live Poisson stream started. "
          f"1 real minute = {MINUTES_PER_SIM_HOUR} sim hour(s).")
    print(f"Hostel curfew hits at simulated hour {HOSTEL_CURFEW_HOUR}:00.")
    start_time = time.time()
    while True:
        elapsed_min = (time.time() - start_time) / 60
        elapsed_sim_hours = elapsed_min / MINUTES_PER_SIM_HOUR
        hour = int(elapsed_sim_hours % 24)
        seconds_per_sim_hour = MINUTES_PER_SIM_HOUR * 60
        seconds_to_hour_end = max((1 - (elapsed_sim_hours % 1)) * seconds_per_sim_hour, 0.01)

        # Exponential inter-arrival gaps are the defining property of a
        # Poisson process. Resampling at an hour boundary keeps this exact
        # when the piecewise rate changes (especially at the evening spike).
        gap_seconds = random.expovariate(demand_lambda_for_hour(hour)) * seconds_per_sim_hour
        if gap_seconds >= seconds_to_hour_end:
            time.sleep(seconds_to_hour_end)
            continue

        time.sleep(gap_seconds)
        event = make_event(hour, is_historical=False, sim_timestamp=datetime.utcnow())
        producer.send(TOPIC, value=event)
        print(f"[sim {hour:02d}:00] {event}")


if __name__ == "__main__":
    run_historical_burst()
    run_live_stream()
