# R/06_read_live_orders.R
#
# The R side of the streaming layer. Connects to the Postgres table that
# consumer.py is writing into, and exposes two small helpers:
#
#   get_live_queue_length(outlet_id)  -> avg queue length from recent orders
#   get_live_sim_hour()               -> the most recent simulated hour seen
#
# These let app_live.R use REAL streamed data (via Kafka -> Postgres) for
# scoring instead of the static tidymodels prediction used in the core
# (non-streaming) app.R. Requires the streaming layer to be running:
#   cd streaming && docker compose up -d
#   python producer.py   (in one terminal)
#   python consumer.py   (in another terminal)

library(DBI)
library(RPostgres)
library(dplyr)

connect_dynaroute_db <- function() {
  dbConnect(
    RPostgres::Postgres(),
    host = "localhost",
    port = 5432,
    dbname = "dynaroute",
    user = "dynaroute",
    password = "dynaroute"
  )
}

# ---- Average queue length for one outlet over the last N minutes -----------
get_live_queue_length <- function(outlet_id, lookback_minutes = 3) {
  con <- connect_dynaroute_db()
  on.exit(dbDisconnect(con))

  query <- sprintf("
    SELECT AVG(queue_length) AS avg_queue
    FROM orders
    WHERE outlet_id = '%s'
      AND received_at > now() - interval '%d minutes'
  ", outlet_id, lookback_minutes)

  result <- dbGetQuery(con, query)
  avg_q <- result$avg_queue[1]

  if (is.na(avg_q)) return(2)  # fallback if no recent orders for this outlet
  avg_q
}

# ---- The most recent simulated hour seen in the stream ----------------------
get_live_sim_hour <- function() {
  con <- connect_dynaroute_db()
  on.exit(dbDisconnect(con))

  result <- dbGetQuery(con, "
    SELECT sim_hour FROM orders
    ORDER BY received_at DESC
    LIMIT 1
  ")

  if (nrow(result) == 0) return(NA)
  result$sim_hour[1]
}

# ---- Quick manual check --------------------------------------------------
# get_live_sim_hour()
# get_live_queue_length("O1")
