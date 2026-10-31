# app_live.R
#
# Same dashboard as app.R, but scored using REAL streamed data instead of
# the static tidymodels prediction — queue lengths come from Kafka ->
# consumer.py -> Postgres, polled here with shiny::reactivePoll().
#
# Prerequisites:
#   1. cd streaming && docker compose up -d
#   2. python producer.py     (separate terminal)
#   3. python consumer.py     (separate terminal)
#   4. Rscript -e "shiny::runApp('app_live.R')"
#
# If the streaming layer isn't running, this app will show stale/fallback
# values rather than crash — see get_live_queue_length()'s fallback.

library(shiny)
library(leaflet)
library(sf)
library(dplyr)

source("R/01_build_network.R", local = FALSE)  # not re-run; city_network.rds already exists
source("R/06_read_live_orders.R")

city_network <- readRDS("city_network.rds")
outlets      <- readRDS("outlets.rds")
hostel_node  <- readRDS("hostel_node.rds")

outlets_ll <- st_transform(outlets, 4326)
hostel_ll  <- st_transform(hostel_node$geometry, 4326)

BLOCKED_SCORE <- 1e6

get_travel_time_min <- function(network, from_point, to_point) {
  path <- sfnetworks::st_network_paths(
    network, from = from_point, to = to_point, weights = "travel_time_min"
  )
  edge_ids <- path$edge_paths[[1]]
  edges_sf <- network %>% sfnetworks::activate("edges") %>% st_as_sf()
  sum(edges_sf$travel_time_min[edge_ids])
}

is_blocked_by_curfew <- function(customer_point, sim_hour) {
  dist_to_hostel <- st_distance(customer_point, hostel_node$geometry)
  near_hostel <- as.numeric(dist_to_hostel) < 100
  near_hostel && sim_hour >= hostel_node$curfew_hour
}

# score every outlet using LIVE queue length pulled from Postgres
assign_best_outlet_live <- function(customer_point, sim_hour) {
  scored <- outlets %>%
    rowwise() %>%
    mutate(
      live_queue = get_live_queue_length(outlet_id),
      blocked = is_blocked_by_curfew(customer_point, sim_hour),
      expected_time_min = if (blocked) {
        BLOCKED_SCORE
      } else {
        get_travel_time_min(city_network, geometry, customer_point) +
          (live_queue * avg_prep_time_min)
      }
    ) %>%
    ungroup() %>%
    arrange(expected_time_min)

  best <- scored %>% slice(1)
  if (best$expected_time_min >= BLOCKED_SCORE) return(NULL)

  list(
    chosen_outlet = best$outlet_id,
    expected_time_min = round(best$expected_time_min, 1),
    all_scores = scored %>% select(outlet_id, live_queue, expected_time_min)
  )
}

ui <- fluidPage(
  titlePanel("LastMile — LIVE mode (Kafka → Postgres → Shiny)"),
  sidebarLayout(
    sidebarPanel(
      h4("Current simulated time"),
      textOutput("sim_clock"),
      hr(),
      h4("Assignment result (from live queue data)"),
      textOutput("assignment_text"),
      tableOutput("score_table"),
      hr(),
      helpText("Click the map to place a customer. Make sure producer.py and consumer.py are running.")
    ),
    mainPanel(leafletOutput("map", height = 600))
  )
)

server <- function(input, output, session) {
  customer_point <- reactiveVal(NULL)

  live_tick <- reactivePoll(
    3000, session,
    checkFunc = function() get_live_sim_hour(),
    valueFunc = function() get_live_sim_hour()
  )

  output$map <- renderLeaflet({
    leaflet() %>%
      addTiles() %>%
      addCircleMarkers(data = outlets_ll, label = ~outlet_id, color = "#065A82", radius = 8) %>%
      addCircleMarkers(data = hostel_ll, label = "Hostel (curfew node)", color = "#F4845F", radius = 8)
  })

  observeEvent(input$map_click, {
    click <- input$map_click
    pt <- st_sfc(st_point(c(click$lng, click$lat)), crs = 4326) %>%
      st_transform(st_crs(city_network))
    customer_point(pt)
  })

  output$sim_clock <- renderText({
    h <- live_tick()
    if (is.na(h)) return("No live data yet — is the streaming layer running?")
    paste0("Simulated hour: ", sprintf("%02d:00", h))
  })

  result <- reactive({
    req(customer_point())
    h <- live_tick()
    req(!is.na(h))
    assign_best_outlet_live(customer_point(), h)
  })

  output$assignment_text <- renderText({
    if (is.null(customer_point())) return("No customer location selected yet.")
    res <- result()
    if (is.null(res)) return("This location can't be served right now (curfew active).")
    paste0("Best outlet: ", res$chosen_outlet, " — expected ", res$expected_time_min, " min")
  })

  output$score_table <- renderTable({
    req(result())
    result()$all_scores
  })
}

shinyApp(ui, server)
