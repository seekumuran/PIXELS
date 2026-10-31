# 01_build_network.R
#
# Pulls a real road network from OpenStreetMap and turns it into a routable
# graph using sfnetworks. This graph is the backbone everything else in the
# project sits on top of: nodes are intersections/points of interest, edges
# are streets, and the initial edge weight is just travel time from length.

library(osmdata)
library(sf)
library(sfnetworks)
library(dplyr)

# ---- Config -----------------------------------------------------------
place_name <- "Chennai, Tamil Nadu, India"   # change this to your target city
walking_speed_kmph <- 20                     # rough scooter/bike delivery speed

# ---- 1. Download the road network -------------------------------------
message("Downloading OSM road network for: ", place_name)

bbox <- getbb(place_name)

osm_data <- opq(bbox = bbox) %>%
  add_osm_feature(key = "highway") %>%
  osmdata_sf()

edges <- osm_data$osm_lines %>%
  select(osm_id, name, highway, geometry) %>%
  filter(!is.na(highway))

# ---- 2. Build the sfnetwork ---------------------------------------------
message("Building routable graph...")

city_network <- as_sfnetwork(edges, directed = FALSE) %>%
  activate("edges") %>%
  mutate(
    length_m = sf::st_length(geometry) %>% as.numeric(),
    # initial weight: pure travel time in minutes, before any demand adjustment
    travel_time_min = (length_m / 1000) / walking_speed_kmph * 60
  )

# ---- 3. Save for the rest of the pipeline --------------------------------
saveRDS(city_network, "city_network.rds")

message(
  "Network built: ",
  nrow(city_network %>% activate("nodes") %>% st_as_sf()), " nodes, ",
  nrow(city_network %>% activate("edges") %>% st_as_sf()), " edges."
)
message("Saved to city_network.rds")
