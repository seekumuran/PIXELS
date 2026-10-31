"""
producer.py

The "producer" in the streaming layer. Simulates a live stream of delivery
orders and publishes each one as a JSON message to a Kafka/Redpanda topic.

To make a demo actually show the hostel-curfew pattern without waiting a
real 24 hours, this uses a COMPRESSED CLOCK: one real minute = one
simulated hour, so a full simulated day cycles roughly every 24 minutes,
and you'll see the curfew hit within a few minutes of starting it.

Usage:
    pip install -r requirements.txt
    python producer.py
"""

import json
import random
import time
from datetime import datetime

from kafka import KafkaProducer

TOPIC = "orders_raw"
BOOTSTRAP_SERVERS = ["localhost:9092"]

OUTLETS = ["O1", "O2", "O3", "O4", "O5", "O6"]
HOSTEL_CURFEW_HOUR = 20          # matches R/02_simulate_orders.R
MINUTES_PER_SIM_HOUR = 1.0       # 1 real minute == 1 simulated hour

# Same Poisson-process rates used in R/02_simulate_orders.R, so the live
# stream and the offline simulation behave consistently. Orders arrive as a
# non-homogeneous Poisson process: rate = BASELINE_RATE, bumped up to
# BASELINE_RATE + HOSTEL_RATE during the evening spike. Instead of a flat
# random.uniform(1, 3) sleep, the gap between orders is drawn from an
# Exponential(rate) distribution, which is what "orders/hour at rate lambda"
# actually implies (memoryless inter-arrival times).
BASELINE_RATE = 3   # orders/sim-hour outside the spike
HOSTEL_RATE = 12    # additional orders/sim-hour during the spike

producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)


def current_sim_hour(start_time: float) -> int:
    elapsed_min = (time.time() - start_time) / 60
    return int((elapsed_min / MINUTES_PER_SIM_HOUR) % 24)


def make_order(sim_hour: int) -> dict:
    is_hostel_spike = 18 <= sim_hour < HOSTEL_CURFEW_HOUR

    if is_hostel_spike:
        # heavy demand skewed toward whichever outlet is "closest" to the hostel
        # (kept simple here — real spatial join happens on the R side)
        outlet_id = random.choices(OUTLETS, weights=[3, 3, 1, 1, 1, 1])[0]
        queue_length = random.randint(6, 16)
    else:
        outlet_id = random.choice(OUTLETS)
        queue_length = random.randint(0, 5)

    return {
        "outlet_id": outlet_id,
        "sim_hour": sim_hour,
        "queue_length": queue_length,
        "produced_at": datetime.utcnow().isoformat(),
    }


def sim_rate_per_hour(sim_hour: int) -> float:
    """orders/sim-hour right now, matching R/02_simulate_orders.R's lambda(h)."""
    is_spike = 18 <= sim_hour < HOSTEL_CURFEW_HOUR
    return BASELINE_RATE + (HOSTEL_RATE if is_spike else 0)


def next_gap_seconds(sim_hour: int) -> float:
    """
    Real-world seconds to wait before the next order, given the current
    sim-hour's Poisson rate. Exponential(rate) inter-arrival times in
    sim-hours, converted to real seconds via the compressed clock.
    """
    rate_per_sim_hour = sim_rate_per_hour(sim_hour)
    gap_sim_hours = random.expovariate(rate_per_sim_hour)
    real_seconds_per_sim_hour = MINUTES_PER_SIM_HOUR * 60
    return gap_sim_hours * real_seconds_per_sim_hour


def run():
    start_time = time.time()
    print(f"Producer started. Topic: {TOPIC}. 1 real minute = {MINUTES_PER_SIM_HOUR} sim hour(s).")
    print(f"Hostel curfew hits at simulated hour {HOSTEL_CURFEW_HOUR}:00.")

    while True:
        sim_hour = current_sim_hour(start_time)
        order = make_order(sim_hour)
        producer.send(TOPIC, value=order)
        print(f"[sim {sim_hour:02d}:00] sent order -> {order}")
        time.sleep(next_gap_seconds(sim_hour))  # Poisson-process inter-arrival gap


if __name__ == "__main__":
    run()
