# R/dev_synthetic_network.R
#
# Builds a small synthetic grid road network in-memory — no internet, no
# OpenStreetMap download, ready in under a second. Use this while developing
# so you're not waiting on a full-city OSM pull every time you tweak logic
# in 02-06. Produces the exact same city_network.rds shape as
# 01_build_network.R, so every downstream script works unmodified.
#
# Usage:
#   source("R/dev_synthetic_network.R")
#   # then run 02_simulate_orders.R, 03_demand_model.R, etc. as normal

library(sf)
library(sfnetworks)
library(tidygraph)
library(dplyr)

set.seed(7)

# ---- Config -----------------------------------------------------------
grid_size <- 10           # 10x10 grid of intersections (~6 km across)
spacing_deg <- 0.006      # ~600m between adjacent intersections
center_lon <- 80.2707     # Chennai — change freely, it's fake data anyway
center_lat <- 13.0827
walking_speed_kmph <- 20

# ---- 1. Build grid nodes ---------------------------------------------------
coords <- expand.grid(i = 0:(grid_size - 1), j = 0:(grid_size - 1)) %>%
  mutate(
    lon = center_lon + (i - grid_size / 2) * spacing_deg,
    lat = center_lat + (j - grid_size / 2) * spacing_deg
  )

# ---- 2. Connect each node to its right and top neighbor (grid streets) ----
make_edge <- function(i1, j1, i2, j2) {
  p1 <- coords[coords$i == i1 & coords$j == j1, ]
  p2 <- coords[coords$i == i2 & coords$j == j2, ]
  st_linestring(rbind(c(p1$lon, p1$lat), c(p2$lon, p2$lat)))
}

edge_list <- list()
for (i in 0:(grid_size - 1)) {
  for (j in 0:(grid_size - 1)) {
    if (i < grid_size - 1) edge_list[[length(edge_list) + 1]] <- make_edge(i, j, i + 1, j)
    if (j < grid_size - 1) edge_list[[length(edge_list) + 1]] <- make_edge(i, j, i, j + 1)
  }
}

edges_sf <- st_sf(
  osm_id = as.character(seq_along(edge_list)),
  name = "synthetic_street",
  highway = "residential",
  geometry = st_sfc(edge_list, crs = 4326)
)

# ---- 3. Build the sfnetwork (same shape as 01_build_network.R's output) ---
city_network <- as_sfnetwork(edges_sf, directed = FALSE) %>%
  convert(to_spatial_subdivision, .clean = TRUE) %>%
  convert(to_largest_component) %>%
  activate("edges") %>%
  mutate(
    length_m = sf::st_length(geometry) %>% as.numeric(),
    travel_time_min = (length_m / 1000) / walking_speed_kmph * 60
  )

saveRDS(city_network, "city_network.rds")

message(
  "Synthetic dev network built: ",
  nrow(city_network %>% activate("nodes") %>% st_as_sf()), " nodes, ",
  nrow(city_network %>% activate("edges") %>% st_as_sf()), " edges."
)
message("Saved to city_network.rds — this is a stand-in grid, NOT real roads.")
