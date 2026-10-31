# 05_demand_clusters.R
#
# Finds geographic demand hotspots from order locations using DBSCAN.
# Unlike k-means, DBSCAN doesn't require guessing the number of clusters
# up front — it finds dense regions of arbitrary shape, which suits
# organic demand patterns (a crowd near a college gate, a cluster of
# offices, etc.) much better than forcing a fixed number of centers.

library(dbscan)
library(sf)
library(dplyr)

orders <- readRDS("simulated_orders.rds")
outlets <- readRDS("outlets.rds")

# For this demo, approximate each order's location as a small random jitter
# around a random outlet, since we don't have real per-order coordinates.
# Replace this block with real order coordinates if you have them.
set.seed(1)
order_coords <- orders %>%
  left_join(
    outlets %>% st_coordinates() %>% as_tibble() %>%
      bind_cols(outlet_id = outlets$outlet_id),
    by = "outlet_id"
  ) %>%
  mutate(
    lon = X + rnorm(n(), 0, 0.003),
    lat = Y + rnorm(n(), 0, 0.003)
  ) %>%
  select(outlet_id, hour, lon, lat)

# ---- Run DBSCAN ------------------------------------------------------------
# eps: neighborhood radius in degrees. Order points are jittered with a
# stddev of ~0.003 around their outlet (see above), so eps needs to be
# comfortably larger than that or almost every point ends up classified as
# noise instead of forming a cluster. ~0.006 ≈ 650m at this latitude.
# minPts: minimum orders to form a dense cluster.
coords_matrix <- order_coords %>% select(lon, lat) %>% as.matrix()

clustering <- dbscan(coords_matrix, eps = 0.006, minPts = 4)

order_coords$cluster_id <- clustering$cluster  # 0 = noise / not in a hotspot

hotspots <- order_coords %>%
  filter(cluster_id != 0) %>%
  group_by(cluster_id) %>%
  summarise(
    n_orders = n(),
    center_lon = mean(lon),
    center_lat = mean(lat),
    .groups = "drop"
  ) %>%
  arrange(desc(n_orders))

saveRDS(order_coords, "order_coords_clustered.rds")
saveRDS(hotspots, "demand_hotspots.rds")

message(nrow(hotspots), " demand hotspot(s) detected out of ", nrow(order_coords), " orders.")
print(hotspots)
