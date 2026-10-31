# app.R
#
# The dashboard: click the map to drop a customer pin, drag the time slider,
# and see which outlet gets assigned as the hour changes — including the
# hostel curfew cutoff. Toggle the heatmap to see demand hotspots from
# 05_demand_clusters.R.
#
# Live-order simulation note: instead of a real message broker, this app
# uses shiny::reactivePoll() to re-check for "new" simulated orders every
# few seconds — this is the lightweight stand-in for a producer/consumer
# stream described in the project write-up.

library(shiny)
library(leaflet)
library(leaflet.extras)
library(sf)
library(dplyr)

source("R/04_dynamic_scoring.R")  # brings in assign_best_outlet(), city_network, outlets

hotspots <- tryCatch(readRDS("demand_hotspots.rds"), error = function(e) NULL)
order_coords <- tryCatch(readRDS("order_coords_clustered.rds"), error = function(e) NULL)

outlets_ll <- st_transform(outlets, 4326)
hostel_ll  <- st_transform(hostel_node$geometry, 4326)

ui <- fluidPage(
  titlePanel("LastMile: Real-Time Geospatial Routing"),
  sidebarLayout(
    sidebarPanel(
      sliderInput("hour", "Time of day", min = 0, max = 23, value = 19, step = 1,
                  animate = animationOptions(interval = 1200)),
      checkboxInput("show_heatmap", "Show demand heatmap", value = FALSE),
      hr(),
      h4("Assignment result"),
      textOutput("assignment_text"),
      tableOutput("score_table"),
      hr(),
      helpText("Click anywhere on the map to place a customer and see which outlet gets assigned.")
    ),
    mainPanel(
      leafletOutput("map", height = 600)
    )
  )
)

server <- function(input, output, session) {

  customer_point <- reactiveVal(NULL)

  # simulate a "live" data refresh every 5 seconds (stand-in for a real stream)
  live_tick <- reactivePoll(
    5000, session,
    checkFunc = function() Sys.time(),
    valueFunc = function() Sys.time()
  )

  output$map <- renderLeaflet({
    leaflet() %>%
      addTiles() %>%
      addCircleMarkers(
        data = outlets_ll, label = ~outlet_id,
        color = "#065A82", radius = 8, fillOpacity = 0.9
      ) %>%
      addCircleMarkers(
        data = hostel_ll, label = "Hostel (curfew node)",
        color = "#F4845F", radius = 8, fillOpacity = 0.9
      )
  })

  observeEvent(input$map_click, {
    click <- input$map_click
    pt <- st_sfc(st_point(c(click$lng, click$lat)), crs = 4326) %>%
      st_transform(st_crs(city_network))
    customer_point(pt)

    leafletProxy("map") %>%
      clearGroup("customer") %>%
      addCircleMarkers(
        lng = click$lng, lat = click$lat,
        group = "customer", color = "black", radius = 6
      )
  })

  assignment <- reactive({
    req(customer_point())
    live_tick()  # depend on the poll so this recomputes as "new data" arrives
    assign_best_outlet(customer_point(), hour = input$hour)
  })

  output$assignment_text <- renderText({
    res <- assignment()
  
    if (is.null(res)) {
      return("This location is outside the LastMile service area.")
    }
  
    paste0(
      "Best outlet: ",
      res$chosen_outlet,
      " — expected ",
      res$expected_time_min,
      " min"
    )
  })

  output$score_table <- renderTable({
    res <- assignment()
    req(res)
  
    as.data.frame(res$all_scores)
  })

  observe({
    if (isTRUE(input$show_heatmap) && !is.null(order_coords)) {
      leafletProxy("map") %>%
        clearHeatmap() %>%
        addHeatmap(data = order_coords, lng = ~lon, lat = ~lat, radius = 35, blur = 40)
    } else {
      leafletProxy("map") %>% clearHeatmap()
    }
  })
}

shinyApp(ui, server)
