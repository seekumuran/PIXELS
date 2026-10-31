# run_pipeline.R
#
# Runs the full non-streaming pipeline end to end, in the correct order.
#
# Usage:
#   Rscript run_pipeline.R            # real OSM data (needs internet, slower)
#   Rscript run_pipeline.R --fast     # synthetic dev network (instant, for testing logic)

args <- commandArgs(trailingOnly = TRUE)
use_synthetic <- "--fast" %in% args

message("== Step 1/4: network ==")
if (use_synthetic) {
  source("R/dev_synthetic_network.R")
} else {
  source("R/01_build_network.R")
}

message("== Step 2/4: simulate orders ==")
source("R/02_simulate_orders.R")

message("== Step 3/4: demand model ==")
source("R/03_demand_model.R")

message("== Step 4/4: demand clusters ==")
source("R/05_demand_clusters.R")

message("")
message("Pipeline complete. Run the dashboard with:")
message("  shiny::runApp('app.R')")
