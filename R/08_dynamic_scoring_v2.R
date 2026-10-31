# R/08_dynamic_scoring_v2.R
#
# The "dynamic graph" engine. Recomputes every edge's CURRENT travel time
# from traffic and weather factors, blocks edges near the hostel after
# curfew, scores every outlet on the CURRENT graph in a plain loop (kept
# deliberately simple/readable over a rowwise-list-column approach), and
# returns a full per-outlet breakdown plus the winning route's geometry.
#
# Does not modify R/04_dynamic_scoring.R -- this is a separate engine used
# only by app_v2.R.

library(sf)
library(sfnetworks)
library(tidygraph)
library(dplyr)

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")

BLOCKED_EDGE_WEIGHT   <- 1e6   # effectively "infinite" for a single edge
HOSTEL_BLOCK_RADIUS_M <- 350   # edges within this distance of the hostel are
                                # treated as curfew-affected once curfew hits

# ---- Recompute every edge's current travel time -----------------------
update_dynamic_network <- function(network, hour, traffic_factor, weather_factor,
                                    hostel_point = NULL, curfew_hour = NULL) {
  edges_sf <- network %>% activate("edges") %>% st_as_sf()

  blocked <- rep(FALSE, nrow(edges_sf))
  if (!is.null(hostel_point) && !is.null(curfew_hour) && hour >= curfew_hour) {
    edge_midpoints <- st_centroid(edges_sf$geometry)
    dist_to_hostel <- as.numeric(st_distance(edge_midpoints, hostel_point))
    blocked <- dist_to_hostel < HOSTEL_BLOCK_RADIUS_M
  }

  current_travel_time_min <- if_else(
    blocked,
    BLOCKED_EDGE_WEIGHT,
    edges_sf$travel_time_min * traffic_factor * weather_factor
  )

  network %>%
    activate("edges") %>%
    mutate(
      base_travel_time_min = edges_sf$travel_time_min,
      traffic_factor = traffic_factor,
      weather_factor = weather_factor,
      blocked = blocked,
      current_travel_time_min = current_travel_time_min
    )
}

# ---- Travel time + route path on the CURRENT network, computed once ---------
# Distinguishes "same node" (0 min, route_found = TRUE) from "genuinely no
# path found" (route_found = FALSE) instead of collapsing both to 0 -- an
# unreachable outlet must never look identical to a zero-distance one.
get_route_info <- function(network, from_point, to_point) {
  path <- sfnetworks::st_network_paths(
    network, from = from_point, to = to_point, weights = "current_travel_time_min"
  )
  edge_ids <- path$edge_paths[[1]]

  if (length(edge_ids) == 0) {
    same_point <- as.numeric(st_distance(from_point, to_point)) < 5
    if (same_point) {
      return(list(travel_time = 0, edge_count = 0, route_found = TRUE, route_line = NULL))
    }
    return(list(travel_time = Inf, edge_count = 0, route_found = FALSE, route_line = NULL))
  }

  edges_sf <- network %>% activate("edges") %>% st_as_sf()
  travel_time <- sum(edges_sf$current_travel_time_min[edge_ids])
  route_geom <- edges_sf$geometry[edge_ids] %>% st_union()
  route_line <- if (inherits(route_geom, "sfc_MULTILINESTRING")) {
    st_line_merge(route_geom)
  } else {
    route_geom  # already a single LINESTRING -- nothing to merge
  }

  list(travel_time = travel_time, edge_count = length(edge_ids), route_found = TRUE, route_line = route_line)
}

# ---- Assign the best outlet using current conditions ---------------------
# customer_point_4326: the raw click, lon/lat (EPSG:4326)
# service_area: convex-hull polygon from build_service_area(), secondary check
# live_queue_lookup: optional function(outlet_id) -> extra queue count.
#                     NULL if the streaming layer isn't running.
assign_best_outlet_dynamic <- function(customer_point_4326, hour,
                                        network, outlets_df, model,
                                        hostel_pt, curfew_hour,
                                        service_area = NULL,
                                        live_queue_lookup = NULL) {

  if (!is.null(service_area) &&
      !is_within_service_area(customer_point_4326, network, service_area)) {
    return(list(status = "outside_service_area"))
  }

  customer_point <- st_transform(customer_point_4326, st_crs(network))

  # Curfew only blocks customers actually near the hostel -- unrelated
  # locations are never rejected because of it.
  dist_to_hostel <- as.numeric(st_distance(customer_point, hostel_pt))
  if (dist_to_hostel < HOSTEL_BLOCK_RADIUS_M && hour >= curfew_hour) {
    return(list(status = "hostel_curfew"))
  }

  traffic <- get_traffic_state(hour)
  weather <- get_weather_state()
  dyn_network <- update_dynamic_network(
    network, hour, traffic$factor, weather$factor,
    hostel_point = hostel_pt, curfew_hour = curfew_hour
  )

  rows <- vector("list", nrow(outlets_df))
  route_infos <- list()

  for (i in seq_len(nrow(outlets_df))) {
    outlet_id  <- outlets_df$outlet_id[i]
    outlet_geom <- outlets_df$geometry[i]
    avg_prep   <- outlets_df$avg_prep_time_min[i]

    route_info <- get_route_info(dyn_network, outlet_geom, customer_point)
    route_infos[[outlet_id]] <- route_info

    predicted_queue <- predict_queue_length(model, outlet_id, hour)
    live_boost <- if (!is.null(live_queue_lookup)) live_queue_lookup(outlet_id) else 0

    expected_time <- if (!route_info$route_found || route_info$travel_time >= BLOCKED_EDGE_WEIGHT) {
      Inf
    } else {
      route_info$travel_time + ((predicted_queue + live_boost) * avg_prep)
    }

    rows[[i]] <- data.frame(
      outlet_id = outlet_id,
      travel_time_min = route_info$travel_time,
      predicted_queue = predicted_queue,
      live_queue_boost = live_boost,
      traffic_factor = traffic$factor,
      weather_factor = weather$factor,
      expected_time_min = expected_time,
      route_found = route_info$route_found,
      stringsAsFactors = FALSE
    )
  }

  scored <- bind_rows(rows) %>% arrange(expected_time_min)
  best <- scored %>% slice(1)

  if (!is.finite(best$expected_time_min)) {
    return(list(status = "no_outlet_reachable", traffic = traffic, weather = weather))
  }

  best_route <- route_infos[[best$outlet_id]]
  best_avg_prep <- outlets_df$avg_prep_time_min[outlets_df$outlet_id == best$outlet_id]

  list(
    status = "ok",
    chosen_outlet = best$outlet_id,
    expected_time_min = round(best$expected_time_min, 1),
    travel_time_min = round(best$travel_time_min, 1),
    predicted_queue = round(best$predicted_queue, 1),
    live_queue_boost = round(best$live_queue_boost, 1),
    prep_contribution_min = round((best$predicted_queue + best$live_queue_boost) * best_avg_prep, 1),
    traffic = traffic,
    weather = weather,
    route_line_projected = best_route$route_line,
    route_edge_count = best_route$edge_count,
    all_scores = scored %>%
      mutate(
        travel_time_min = round(travel_time_min, 1),
        predicted_queue = round(predicted_queue, 1),
        live_queue_boost = round(live_queue_boost, 1),
        expected_time_min = ifelse(is.finite(expected_time_min), round(expected_time_min, 1), NA),
        status = ifelse(route_found & is.finite(expected_time_min), "Available", "Blocked")
      ) %>%
      select(outlet_id, travel_time_min, predicted_queue, live_queue_boost,
             traffic_factor, weather_factor, expected_time_min, status)
  )
}
