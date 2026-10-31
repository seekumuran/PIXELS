# 02_simulate_orders.R
#
# There's no real order-history dataset behind a course project, so this
# script generates plausible fake data instead:
#   - a handful of outlets scattered across the city
#   - a stream of simulated orders across a day, with a demand spike around
#     a "hostel" location that goes quiet after a curfew hour — this is the
#     pattern the demand model in 03_demand_model.R will learn to recognize.

library(sf)
library(dplyr)
library(lubridate)
library(purrr)

set.seed(42)

city_network <- readRDS("city_network.rds")
nodes_sf <- city_network %>% sfnetworks::activate("nodes") %>% st_as_sf()

# ---- 1. Place outlets ----------------------------------------------------
n_outlets <- 12
outlet_nodes <- nodes_sf %>% slice_sample(n = n_outlets)

outlets <- outlet_nodes %>%
  mutate(
    outlet_id = paste0("O", row_number()),
    # tightened range so one outlet's fixed prep time can't single-handedly
    # dominate the scoring formula regardless of distance or demand
    avg_prep_time_min = round(runif(n(), 6, 8), 1)
  ) %>%
  select(outlet_id, avg_prep_time_min, geometry)

# ---- 2. Mark one "hostel" node with a curfew ------------------------------
hostel_node <- nodes_sf %>% slice_sample(n = 1) %>%
  mutate(location_id = "HOSTEL_1", curfew_hour = 20)  # no deliveries after 8 PM

# Outlets physically closer to the hostel should realistically get more of
# its order volume than outlets across town. Without this, hostel demand is
# spread uniformly across every outlet, the demand model never learns any
# real outlet-specific signal, and assignment ends up driven almost entirely
# by each outlet's fixed avg_prep_time_min instead of location or time.
dist_to_hostel <- as.numeric(sf::st_distance(outlets$geometry, hostel_node$geometry))
proximity_weight <- 1 / (dist_to_hostel + 1)
hostel_outlet_weights <- proximity_weight / sum(proximity_weight)

# ---- 3. Simulate a day of orders as a Poisson process ---------------------
# Orders arrive according to a non-homogeneous Poisson process: the rate
# lambda(t) is a step function of hour —
#     lambda(h) = baseline_rate + hostel_rate(h)
# where hostel_rate(h) = 12/hr during the evening spike (18:00 up to the
# curfew hour) and 0 otherwise. Because lambda is piecewise-constant, each
# hour-long segment can be simulated EXACTLY (no thinning/approximation
# needed): keep drawing Exp(rate) inter-arrival gaps and stop once they'd
# overrun the hour. This gives every order a real arrival timestamp instead
# of just a per-hour count.
#
# Whether an individual arrival is a "hostel" order is then an independent
# coin flip with probability hostel_rate/rate — splitting a Poisson process
# by an independent mark like this yields exactly the two sub-processes we
# want (baseline vs. hostel-driven), so it's equivalent to the old two-call
# rpois() approach but with real timing instead of hourly buckets.

baseline_rate <- 3   # orders/hour — matches the old rpois(lambda = 3)
hostel_rate   <- 12  # orders/hour during the spike — matches rpois(lambda = 12)

simulate_hour_arrivals <- function(hour) {
  is_spike <- hour >= 18 && hour < hostel_node$curfew_hour
  rate <- baseline_rate + if (is_spike) hostel_rate else 0

  # Exact simulation of a homogeneous Poisson process over one hour.
  t <- 0
  arrival_times <- numeric(0)
  repeat {
    t <- t + rexp(1, rate = rate)
    if (t >= 1) break
    arrival_times <- c(arrival_times, t)
  }
  n <- length(arrival_times)

  if (n == 0) {
    return(tibble(
      hour = integer(0), arrival_time = numeric(0),
      outlet_id = character(0), queue_length_at_order = integer(0),
      is_hostel_order = logical(0)
    ))
  }

  # Mark each arrival as hostel-driven or baseline (see note above).
  p_hostel <- if (is_spike) hostel_rate / rate else 0
  is_hostel <- runif(n) < p_hostel

  n_hostel <- sum(is_hostel)
  n_base   <- n - n_hostel

  outlet_id <- character(n)
  outlet_id[is_hostel]  <- sample(outlets$outlet_id, n_hostel, replace = TRUE, prob = hostel_outlet_weights)
  outlet_id[!is_hostel] <- sample(outlets$outlet_id, n_base, replace = TRUE)

  queue_length_at_order <- integer(n)
  queue_length_at_order[is_hostel]  <- rpois(n_hostel, lambda = 6)
  queue_length_at_order[!is_hostel] <- rpois(n_base, lambda = 2)

  tibble(
    hour = hour,
    arrival_time = hour + sort(arrival_times),
    outlet_id = outlet_id,
    queue_length_at_order = queue_length_at_order,
    is_hostel_order = is_hostel
  )
}

hours <- 0:23

orders <- map_dfr(hours, simulate_hour_arrivals) %>%
  arrange(arrival_time) %>%
  mutate(
    day = "sim_day_1",
    # real wall-clock timestamp for the order, e.g. for plotting/streaming
    timestamp = as.POSIXct("2024-01-01 00:00:00", tz = "UTC") + arrival_time * 3600
  )

# ---- 4. Save everything ----------------------------------------------------
saveRDS(outlets, "outlets.rds")
saveRDS(hostel_node, "hostel_node.rds")
saveRDS(orders, "simulated_orders.rds")

message("Simulated ", nrow(orders), " orders across ", n_outlets, " outlets.")
message("Hostel curfew hour: ", hostel_node$curfew_hour, ":00")
message(
  "Outlet closest to the hostel: ", outlets$outlet_id[which.max(hostel_outlet_weights)],
  " (gets the most hostel-driven demand during the evening spike)"
)
