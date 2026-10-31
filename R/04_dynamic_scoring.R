# 04_dynamic_scoring.R
#
# The heart of the project: for a given customer location and time, score
# every reachable outlet on EXPECTED delivery time (not raw distance) and
# return the best one.
#
#   expected_time = travel_time + (queue_length * avg_prep_time)
#
# Hard time-based constraints (like a delivery curfew) are handled by
# assigning an effectively infinite score to any outlet whose route passes
# through a blocked node during the blocked hours — this is what makes the
# graph "dynamic" rather than a fixed shortest-path problem.

library(sf)
library(sfnetworks)
library(dplyr)
library(tidygraph)

city_network   <- readRDS("city_network.rds")
outlets        <- readRDS("outlets.rds")
hostel_node    <- readRDS("hostel_node.rds")
demand_model   <- readRDS("demand_model.rds")
source("R/03_demand_model.R")  # for predict_queue_length(), harmless to re-source
source("R/00_predict_helpers.R")

BLOCKED_SCORE <- 1e6  # effectively "infinite" — never selected while active

is_location_served <- function(customer_point, network, max_distance_m = 3000) {
  nodes <- network %>%
    activate("nodes") %>%
    st_as_sf()

  nearest <- st_nearest_feature(customer_point, nodes)

  distance <- st_distance(
    customer_point,
    nodes[nearest, ]
  )

  as.numeric(distance) <= max_distance_m
}

# ---- Travel time between customer and a given outlet -----------------------
get_travel_time_min <- function(network, from_point, to_point) {
  # snap both points to the nearest network nodes, then shortest-path travel time
  path <- st_network_paths(
    network,
    from = from_point,
    to = to_point,
    weights = "travel_time_min"
  )
  edge_ids <- path$edge_paths[[1]]
  edges_sf <- network %>% activate("edges") %>% st_as_sf()
  sum(edges_sf$travel_time_min[edge_ids])
}

# ---- Is this delivery blocked by a time-based constraint? ------------------
# Example: the hostel node stops accepting deliveries at its curfew hour.
is_blocked_by_curfew <- function(customer_point, hour) {
  dist_to_hostel <- st_distance(customer_point, hostel_node$geometry)
  near_hostel <- as.numeric(dist_to_hostel) < 100  # within ~100m of the hostel gate
  near_hostel && hour >= hostel_node$curfew_hour
}

# ---- Score a single outlet for a single order -------------------------------
score_outlet <- function(network, outlet_row, customer_point, hour, demand_model) {
  if (is_blocked_by_curfew(customer_point, hour)) {
    return(BLOCKED_SCORE)
  }

  travel_time <- get_travel_time_min(network, outlet_row$geometry, customer_point)
  predicted_queue <- predict_queue_length(demand_model, outlet_row$outlet_id, hour)

  travel_time + (predicted_queue * outlet_row$avg_prep_time_min)
}

# ---- Assign the best outlet for a new order ---------------------------------
assign_best_outlet <- function(customer_point, hour,
                               network = city_network,
                               outlets_df = outlets,
                               model = demand_model) {

  if (!is_location_served(customer_point, network)) {
    message("Customer location is outside the service area.")
    return(NULL)
  }

  scored <- outlets_df %>%
    rowwise() %>%
    mutate(
      expected_time_min = score_outlet(
        network,
        cur_data(),
        customer_point,
        hour,
        model
      )
    ) %>%
    ungroup() %>%
    arrange(expected_time_min)

  best <- scored %>% slice(1)

  if (best$expected_time_min >= BLOCKED_SCORE) {
    message("No outlet can currently serve this location.")
    return(NULL)
  }

  list(
    chosen_outlet = best$outlet_id,
    expected_time_min = round(best$expected_time_min, 1),
    all_scores = scored %>%
      select(outlet_id, expected_time_min)
  )
}

# ---- Example usage ------------------------------------------------------
# customer_point <- st_sfc(st_point(c(79.1325, 12.9165)), crs = st_crs(city_network))
# result <- assign_best_outlet(customer_point, hour = 21)
# print(result$chosen_outlet)
# print(result$all_scores)
