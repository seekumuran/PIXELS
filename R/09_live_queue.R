# R/09_live_queue.R
#
# Reads recent events written by streaming/consumer_v2.py into Postgres and
# turns them into a small "extra queue" number per outlet. This is what lets
# new Kafka events change the best-outlet decision live: as more live orders
# land for an outlet, its effective queue length goes up, which can push its
# expected delivery time past a competing outlet's.
#
# If the streaming layer isn't running, every function here fails safely and
# returns zero/no live data -- the dashboard must keep working using only the
# trained demand model in that case (demo/fallback mode).

library(DBI)
library(RPostgres)
library(dplyr)

LIVE_QUEUE_LOOKBACK_MIN <- 10  # only orders in the last N minutes count
# Widened from 3 -> 10: with 12 outlets splitting the Poisson arrival rate,
# any single outlet only gets ~0.25-1.25 orders/minute on average, so a
# 3-minute window frequently shows 0 for a given outlet just by chance, even
# while the pipeline is working correctly. 10 minutes gives a fairer sample.

connect_live_db <- function() {
  dbConnect(
    RPostgres::Postgres(),
    host = "localhost", port = 5432,
    dbname = "dynaroute", user = "dynaroute", password = "dynaroute"
  )
}

# Returns TRUE if the streaming layer looks reachable right now.
is_streaming_available <- function() {
  tryCatch({
    con <- connect_live_db()
    on.exit(dbDisconnect(con))
    dbGetQuery(con, "SELECT 1")
    TRUE
  }, error = function(e) FALSE)
}

# Returns a named numeric vector: outlet_id -> extra queue count from live orders.
get_live_queue_counts <- function() {
  tryCatch({
    con <- connect_live_db()
    on.exit(dbDisconnect(con))
    result <- dbGetQuery(con, sprintf("
      SELECT outlet_id, COUNT(*) AS n
      FROM live_orders
      WHERE received_at > now() - interval '%d minutes'
      GROUP BY outlet_id
    ", LIVE_QUEUE_LOOKBACK_MIN))

    # Postgres COUNT(*) is bigint -> RPostgres maps it to integer64 (bit64),
    # not a plain double. Left un-converted, that integer64 poisons any
    # downstream arithmetic/bind_rows() it touches once real counts flow in.
    setNames(as.numeric(result$n), result$outlet_id)
  }, error = function(e) {
    setNames(numeric(0), character(0))  # empty -- no live influence
  })
}

# Returns a single-outlet lookup function, ready to hand to
# assign_best_outlet_dynamic(..., live_queue_lookup = make_live_queue_lookup()).
make_live_queue_lookup <- function() {
  counts <- get_live_queue_counts()
  function(outlet_id) {
    if (outlet_id %in% names(counts)) unname(counts[outlet_id]) else 0
  }
}

# Small summary used by the dashboard's "Live Stream" panel.
get_live_stream_summary <- function() {
  tryCatch({
    con <- connect_live_db()
    on.exit(dbDisconnect(con))
    total <- dbGetQuery(con, "SELECT COUNT(*) AS n FROM live_orders")$n
    recent <- dbGetQuery(con, sprintf("
      SELECT COUNT(*) AS n FROM live_orders
      WHERE received_at > now() - interval '%d minutes'
    ", LIVE_QUEUE_LOOKBACK_MIN))$n
    # Same integer64 -> numeric fix: these feed sprintf("%d", ...) in
    # app_v2.R's live_stream_text, which errors on integer64 input.
    list(orders_processed = as.numeric(total), recent_orders = as.numeric(recent))
  }, error = function(e) {
    list(orders_processed = 0, recent_orders = 0)
  })
}
