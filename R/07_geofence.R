# R/07_geofence.R
#
# Defines whether a clicked customer point is serviceable.
#
# The PRIMARY check is distance to the nearest actual network node -- this
# directly answers "can we route from here?" and doesn't depend on the
# shape of any polygon. This matters because real OSM road extracts are
# often not fully connected; after to_largest_component() keeps only the
# single largest connected chunk, the network's true coverage can be
# noticeably smaller (or a different shape) than the whole visible map --
# so a point that looks perfectly central on the map can genuinely be far
# from any node that survived that pruning step.
#
# The convex-hull polygon is kept as a SECONDARY, more permissive check
# (mostly useful for a compact/synthetic network), and as something you can
# render on the map to see the network's actual coverage.

library(sf)
library(sfnetworks)
library(dplyr)

DEFAULT_MAX_SNAP_DISTANCE_M <- 5000  # delivery reach beyond the nearest network node
DEFAULT_SERVICE_AREA_BUFFER_M <- 5000 # delivery-radius buffer around the network hull

# Builds the convex-hull service-area polygon (secondary check / map overlay).
build_service_area <- function(network, buffer_m = DEFAULT_SERVICE_AREA_BUFFER_M) {
  nodes_sf <- network %>% activate("nodes") %>% st_as_sf()
  hull <- nodes_sf %>% st_union() %>% st_convex_hull()
  st_buffer(hull, buffer_m)
}

# point_4326: the raw click, EPSG:4326. Everything else can be in any CRS --
# this function handles the transforms internally so callers don't need to
# get CRS matching right themselves.
is_within_service_area <- function(point_4326, network, service_area = NULL,
                                    max_snap_distance_m = DEFAULT_MAX_SNAP_DISTANCE_M) {
  point_net <- st_transform(point_4326, st_crs(network))
  nodes_sf <- network %>% activate("nodes") %>% st_as_sf()

  nearest_idx <- st_nearest_feature(point_net, nodes_sf)
  dist_to_network <- as.numeric(st_distance(point_net, nodes_sf[nearest_idx, ]))

  if (dist_to_network <= max_snap_distance_m) return(TRUE)

  if (!is.null(service_area)) {
    point_area_crs <- st_transform(point_4326, st_crs(service_area))
    return(as.logical(st_within(point_area_crs, service_area, sparse = FALSE)[1, 1]))
  }

  FALSE
}

# ---- Diagnostic helper -------------------------------------------------
# Run this directly in the R console if the geofence still looks wrong:
#   source("R/07_geofence.R"); service_area_debug_info(readRDS("city_network.rds"))
# If node count looks too small for a whole city, or the bounding box
# doesn't cover where you're clicking, city_network.rds itself only covers
# a small connected chunk of the city -- most likely from
# to_largest_component() during the network build.
service_area_debug_info <- function(network) {
  nodes_sf <- network %>% activate("nodes") %>% st_as_sf()
  bbox <- st_bbox(nodes_sf)
  cat("Network node count:", nrow(nodes_sf), "\n")
  cat("Network CRS:", st_crs(nodes_sf)$input, "\n")
  cat("Network bounding box:\n")
  print(bbox)
}
