# app_v2.R
#
# LastMile v2 dashboard. Demonstrates: customer click -> geofence -> current
# conditions -> dynamic graph weights -> route calculation -> queue
# prediction -> live queue -> best outlet -> expected delivery time.
#
# Only loads existing .rds files -- never downloads OSM data or regenerates
# anything. app.R and app_live.R are untouched and unaffected by this file.
#
# Reactive design (see R/07 and R/08 for the underlying logic):
#   customer_point <- reactiveVal(NULL)   -- set once, on click, nothing else
#   result <- reactive({ ... })           -- depends on customer_point(),
#                                             input$hour, and live_state(), so
#                                             it recomputes automatically when
#                                             ANY of those change, including
#                                             just moving the hour slider with
#                                             no new click.
# No separate click_lng()/click_lat() reactives are used, avoiding the
# stale-reactive bug from the earlier version.

library(shiny)
library(leaflet)
library(sf)
library(leaflet.extras)
library(sfnetworks)
library(tidygraph)
library(dplyr)

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")
source("R/08_dynamic_scoring_v2.R")

# DBI/RPostgres are only needed for the optional live layer.
live_pkgs_available <- tryCatch({
  source("R/09_live_queue.R")
  TRUE
}, error = function(e) FALSE)

# ---- Load existing data -- never regenerated here ---------------------------
city_network <- readRDS("city_network.rds")
outlets      <- readRDS("outlets.rds")
hostel_node  <- readRDS("hostel_node.rds")
demand_model <- readRDS("demand_model.rds")
order_coords <- tryCatch(readRDS("order_coords_clustered.rds"), error = function(e) NULL)

outlets_ll       <- st_transform(outlets, 4326)
simulated_orders <- readRDS("simulated_orders.rds")

MAX_HOURLY_ORDER_COUNT <- max(
  simulated_orders %>% dplyr::count(outlet_id, hour) %>% dplyr::pull(n),
  1
)

# Live-order map markers (Kafka-fed), separate from the simulated/historical
# scale above. Tuned for ~12 outlets splitting a 3-15 orders/sim-hour rate
# over a lookback window (LIVE_QUEUE_LOOKBACK_MIN, from R/09_live_queue.R) --
# adjust if those rates change materially.
MAX_LIVE_ORDER_COUNT <- 15
LIVE_OUTLET_MAP_REFRESH_MS <- 4000
if (!exists("LIVE_QUEUE_LOOKBACK_MIN")) LIVE_QUEUE_LOOKBACK_MIN <- 10

live_order_palette <- colorNumeric(
  palette = c("#2ECC71", "#F1C40F", "#E74C3C"),
  domain = c(0, MAX_LIVE_ORDER_COUNT)
)

get_live_counts_safe <- function() {
  if (live_pkgs_available && isTRUE(is_streaming_available())) {
    get_live_queue_counts()
  } else {
    setNames(numeric(0), character(0))
  }
}

hourly_order_palette <- colorNumeric(
  palette = c("#2ECC71", "#F1C40F", "#E74C3C"),
  domain = c(0, MAX_HOURLY_ORDER_COUNT)
)
TRAFFIC_MAP_COLORS <- c(
  Low = "#2ECC71",
  Moderate = "#F1C40F",
  High = "#E67E22",
  "Very High" = "#E74C3C"
)
service_area    <- build_service_area(city_network)
service_area_ll <- st_transform(service_area, 4326)
hostel_ll       <- st_transform(hostel_node, 4326)
hostel_coords   <- st_coordinates(hostel_ll)[1, ]
outlet_bbox     <- st_bbox(outlets_ll)

# Real-time outlet load, straight from Kafka (via consumer_v2.py -> Postgres
# live_orders). Counts orders received in the last LIVE_QUEUE_LOOKBACK_MIN
# minutes (defined in R/09_live_queue.R), independent of the hour slider --
# Kafka events carry a real timestamp, not a simulated-hour bucket, so this
# reflects "right now," not whatever hour you've dragged the slider to.
# If the streaming layer is offline, every outlet shows 0 (get_live_counts_safe()
# returns an empty vector in that case) rather than falling back to the
# historical simulated_orders.rds counts.
outlet_loads_live <- function(live_counts) {
  outlets_ll %>%
    dplyr::mutate(
      live_order_count = vapply(outlet_id, function(id) {
        if (id %in% names(live_counts)) unname(live_counts[[id]]) else 0
      }, numeric(1), USE.NAMES = FALSE),
      marker_label = paste0(
        outlet_id, ": ", live_order_count,
        " live orders (last ", LIVE_QUEUE_LOOKBACK_MIN, " min)"
      ),
      marker_radius = scales::rescale(
        live_order_count,
        to = c(8, 22),
        from = c(0, MAX_LIVE_ORDER_COUNT)
      ),
      marker_color = live_order_palette(pmin(live_order_count, MAX_LIVE_ORDER_COUNT))
    )
}

# ---- TEMPORARY DEBUG INSTRUMENTATION -----------------------------------
# Logs any error from outlet_loads_live() (or its inputs) to debug_log.txt
# instead of letting it fail silently inside renderLeaflet/leafletProxy.
# Falls back to plain grey markers so the map still renders even if this
# specific step fails, which tells us whether outlet_loads_live() is the
# actual culprit or not. Safe to remove once the real bug is found.
log_debug <- function(label, err) {
  msg <- sprintf("[%s] %s: %s", format(Sys.time()), label, paste(conditionMessage(err), collapse = "; "))
  cat(msg, "\n", file = "debug_log.txt", append = TRUE)
  cat(paste(deparse(sys.calls()), collapse = "\n"), "\n---\n", file = "debug_log.txt", append = TRUE)
  message(msg)
}

get_live_counts_safe_logged <- function() {
  tryCatch(get_live_counts_safe(), error = function(e) {
    log_debug("get_live_counts_safe", e)
    setNames(numeric(0), character(0))
  })
}

outlet_loads_live_safe <- function(live_counts) {
  tryCatch(
    outlet_loads_live(live_counts),
    error = function(e) {
      log_debug("outlet_loads_live", e)
      outlets_ll %>%
        dplyr::mutate(
          live_order_count = 0,
          marker_label = paste0(outlet_id, ": load unavailable (see debug_log.txt)"),
          marker_radius = 10,
          marker_color = "#999999"
        )
    }
  )
}
# ---- END TEMPORARY DEBUG INSTRUMENTATION -------------------------------

ui <- fluidPage(
  tags$head(
    tags$link(rel = "stylesheet", href = "dynaroute_theme.css?v=2"),
    tags$script(HTML("
      function drSetPage(page) {
        Shiny.setInputValue('dr_page', page);
        document.querySelectorAll('.dr-nav-item').forEach(function(el) {
          el.classList.remove('active');
        });
        document.getElementById('dr-nav-' + page).classList.add('active');
      }
    "))
  ),

  tags$div(class = "dr-app",

    tags$div(class = "dr-sidebar",
      tags$div(class = "dr-logo", "Last", tags$span("Mile")),
      tags$a(id = "dr-nav-dashboard", class = "dr-nav-item active",
             onclick = "drSetPage('dashboard')", "Dashboard"),
      tags$a(id = "dr-nav-analytics", class = "dr-nav-item",
             onclick = "drSetPage('analytics')", "Analytics")
    ),

    tags$div(class = "dr-main",

      tags$div(class = "dr-stats",
        tags$div(class = "dr-stat",
          tags$div(class = "dr-stat-label", "Live orders"),
          tags$div(class = "dr-stat-value dr-mono", textOutput("dr_pill_live", inline = TRUE))
        ),
        tags$div(class = "dr-stat",
          tags$div(class = "dr-stat-label", "Avg savings"),
          tags$div(class = "dr-stat-value dr-mono", textOutput("dr_pill_savings", inline = TRUE))
        ),
        tags$div(class = "dr-stat",
          tags$div(class = "dr-stat-label", "Active outlets"),
          tags$div(class = "dr-stat-value dr-mono", textOutput("dr_pill_outlets", inline = TRUE))
        )
      ),

      # ---- Dashboard page ----
      conditionalPanel(
        condition = "typeof input.dr_page === 'undefined' || input.dr_page == 'dashboard'",

        tags$div(class = "dr-topbar", tags$h2("Dashboard")),

        tags$div(class = "dr-grid",

          tags$div(class = "dr-map-card",
            leafletOutput("map", height = 620)
          ),

          tags$div(class = "dr-right-col",

            tags$div(class = "dr-card",
              tags$h4("Time of day"),
              sliderInput("hour", NULL, min = 0, max = 23, value = 19, step = 1,
                          animate = animationOptions(interval = 1500)),
              checkboxInput("show_heatmap", "Show demand heatmap", value = FALSE),
              tags$div(style = "font-size:12px; color:var(--muted); margin-top:6px;",
                textOutput("traffic_text"), textOutput("weather_text")
              )
            ),

            tags$div(class = "dr-card",
              tags$h4("Order assignment"),
              uiOutput("dr_order_summary")
            )
          )
        )
      ),

      # ---- Analytics page ----
      conditionalPanel(
        condition = "input.dr_page == 'analytics'",

        tags$div(class = "dr-topbar", tags$h2("Analytics")),

        tags$div(class = "dr-card",
          tags$h4("Outlet comparison for the selected location"),
          uiOutput("dr_analytics_body")
        )
      ),

      tags$details(style = "margin-top: 18px;",
        tags$summary(class = "dr-tech-toggle", "Technical details (routing debug)"),
        tags$div(class = "dr-card", style = "margin-top: 10px;",
          h4("Customer"), verbatimTextOutput("customer_text"),
          h4("Best Outlet"), verbatimTextOutput("best_outlet_text"),
          h4("Outlet Comparison"), tableOutput("comparison_table"),
          h4("Dynamic Network Status"), tableOutput("network_status_table"),
          h4("Live Stream"), textOutput("live_stream_text"),
          h4("Routing Debug"), verbatimTextOutput("debug_panel")
        )
      )
    )
  )
)



server <- function(input, output, session) {

  live_state <- if (live_pkgs_available) {
    reactivePoll(
      intervalMillis = 3000,
      session = session,
      checkFunc = function() {
        summary <- get_live_stream_summary()
        paste(summary$orders_processed, summary$recent_orders)
      },
      valueFunc = function() {
        available <- is_streaming_available()
        summary <- get_live_stream_summary()
        list(
          available = available,
          lookup = if (available) make_live_queue_lookup() else NULL,
          summary = summary
        )
      }
    )
  } else {
    reactive(list(
      available = FALSE,
      lookup = NULL,
      summary = list(orders_processed = 0, recent_orders = 0)
    ))
  }

  output$map <- renderLeaflet({
    initial_outlet_loads <- outlet_loads_live_safe(get_live_counts_safe_logged())
    initial_traffic <- get_traffic_state(19, add_jitter = FALSE)
    initial_traffic_color <- unname(TRAFFIC_MAP_COLORS[initial_traffic$level])

    leaflet() %>%
      addTiles() %>%
      fitBounds(
        lng1 = outlet_bbox[["xmin"]], lat1 = outlet_bbox[["ymin"]],
        lng2 = outlet_bbox[["xmax"]], lat2 = outlet_bbox[["ymax"]]
      ) %>%
      addPolygons(data = service_area_ll, color = "#1C7293", weight = 3,
            fillOpacity = 0.15, group = "service_area") %>%
      addCircleMarkers(
        data = initial_outlet_loads,
        label = ~marker_label,
        radius = ~marker_radius,
        color = ~marker_color,
        fillColor = ~marker_color,
        fillOpacity = 0.85,
        stroke = TRUE, weight = 1,
        group = "outlets"
      ) %>%
        addLegend(
          position = "bottomright", pal = live_order_palette,
          values = c(0, MAX_LIVE_ORDER_COUNT),
          title = paste0("Live orders (last ", LIVE_QUEUE_LOOKBACK_MIN, " min)"),
          layerId = "live_orders_legend_ctrl"
        ) %>%
        addLegend(
          position = "topright",
          colors = initial_traffic_color,
          labels = paste("Traffic:", initial_traffic$level),
          title = "Current traffic",
          opacity = 0.8,
          layerId = "traffic_legend_ctrl"
        )
  })

  # Traffic legend/color updates with the hour slider. Outlet markers no
  # longer depend on input$hour at all -- see the live-refresh timer below,
  # since Kafka orders carry a real timestamp, not a simulated-hour bucket.
  shiny::observeEvent(input$hour, {
    traffic <- get_traffic_state(input$hour, add_jitter = FALSE)
    traffic_color <- unname(TRAFFIC_MAP_COLORS[traffic$level])

    leafletProxy("map") %>%
      removeControl("traffic_legend_ctrl") %>%
      addLegend(
        position = "topright",
        colors = traffic_color,
        labels = paste("Traffic:", traffic$level),
        title = "Current traffic",
        opacity = 0.8,
        layerId = "traffic_legend_ctrl"
      )
  }, ignoreInit = TRUE)

  # Outlet markers refresh on a timer, independent of the hour slider, so
  # they visibly update as new Kafka orders land in the background -- this
  # is what makes outlet load genuinely "real-time" rather than replaying a
  # static simulated day.
  shiny::observe({
    invalidateLater(LIVE_OUTLET_MAP_REFRESH_MS, session)
    isolate({
      counts <- get_live_counts_safe_logged()
      outlet_loads <- outlet_loads_live_safe(counts)

      leafletProxy("map") %>%
        clearGroup("outlets") %>%
        addCircleMarkers(
          data = outlet_loads,
          label = ~marker_label,
          radius = ~marker_radius,
          color = ~marker_color,
          fillColor = ~marker_color,
          fillOpacity = 0.85,
          stroke = TRUE, weight = 1,
          group = "outlets"
        ) %>%
        removeControl("live_orders_legend_ctrl") %>%
        addLegend(
          position = "bottomright", pal = live_order_palette,
          values = c(0, MAX_LIVE_ORDER_COUNT),
          title = paste0("Live orders (last ", LIVE_QUEUE_LOOKBACK_MIN, " min)"),
          layerId = "live_orders_legend_ctrl"
        )
    })
  })

  # Show the same hostel radius used by the dynamic scoring engine once the
  # curfew begins. It is independent of the customer-click route overlay.
  shiny::observe({
    curfew_active <- input$hour >= hostel_node$curfew_hour[1]
    map <- leafletProxy("map") %>% clearGroup("curfew_zone")

    if (curfew_active) {
      map %>%
        addCircles(
          lng = hostel_coords[["X"]],
          lat = hostel_coords[["Y"]],
          radius = HOSTEL_BLOCK_RADIUS_M,
          color = "#E74C3C",
          fillColor = "#E74C3C",
          fillOpacity = 0.15,
          weight = 2,
          label = "Hostel curfew zone: delivery blocked",
          group = "curfew_zone"
        )
    }
  })

  shiny::observeEvent(input$map_click, {

    click <- input$map_click

    leafletProxy("map") %>%
      clearGroup("customer") %>%
      clearGroup("route") %>%
      clearGroup("best_outlet") %>%
      addCircleMarkers(
        lng = click$lng,
        lat = click$lat,
        group = "customer",
        color = "black",
        radius = 6
      )
  })

  # ---------------------------------------------------------
  # MAIN ROUTING REACTIVE
  # Depends directly on map click + hour slider.
  # No reactiveVal customer_point.
  # No reactiveVal result.
  # ---------------------------------------------------------

  result <- shiny::reactive({

    click <- input$map_click

    req(click)

    customer_point <- st_sfc(
      st_point(
        c(click$lng, click$lat)
      ),
      crs = 4326
    )

    live <- live_state()

    assign_best_outlet_dynamic(
      customer_point,
      hour = input$hour,
      network = city_network,
      outlets_df = outlets,
      model = demand_model,
      hostel_pt = hostel_node$geometry,
      curfew_hour = hostel_node$curfew_hour,
      service_area = service_area_ll,
      live_queue_lookup = live$lookup
    )
  })

  # ---------------------------------------------------------
  # NEW UI (v2): stat strip + dashboard summary + analytics table
  # Paste this block inside server <- function(...) { ... },
  # right after the "MAIN ROUTING REACTIVE" result <- reactive({...}) block.
  # ---------------------------------------------------------

  # Tracks (nearest outlet's time - chosen outlet's time) across the
  # session, for the "Avg savings" stat. Only logs valid assignments.
  savings_log <- reactiveVal(numeric(0))

  observeEvent(result(), {
    res <- result()
    if (!identical(res$status, "ok")) return()

    avail <- res$all_scores %>% dplyr::filter(status == "Available")
    if (nrow(avail) == 0) return()

    nearest <- avail %>% dplyr::slice_min(travel_time_min, n = 1, with_ties = FALSE)
    if (is.na(nearest$expected_time_min) || is.na(res$expected_time_min)) return()

    saving <- nearest$expected_time_min - res$expected_time_min
    savings_log(c(savings_log(), saving))
  })

  output$dr_pill_live <- renderText({
    live <- live_state()
    as.character(live$summary$recent_orders)
  })

  output$dr_pill_savings <- renderText({
    log <- savings_log()
    if (length(log) == 0) "—" else sprintf("%.1f min", mean(log))
  })

  output$dr_pill_outlets <- renderText({
    as.character(nrow(outlets))
  })

  # ---- Dashboard page: compact summary, links to Analytics for detail ----
  output$dr_order_summary <- renderUI({
    click <- input$map_click
    if (is.null(click)) {
      return(tags$div(class = "dr-empty", "Click the map to assign an order."))
    }

    res <- result()

    if (!identical(res$status, "ok")) {
      msg <- switch(res$status,
        "outside_service_area" = "Customer is outside the service area.",
        "hostel_curfew"        = "Hostel curfew is active for this location.",
        "no_outlet_reachable"  = "No outlet can currently reach this location.",
        "Delivery unavailable."
      )
      return(tags$div(class = "dr-empty", msg))
    }

    tagList(
      tags$div(class = "dr-summary-outlet", res$chosen_outlet),
      tags$div(class = "dr-summary-meta",
        sprintf("%.1f min expected · %.1f min travel", res$expected_time_min, res$travel_time_min)
      ),
      tags$a(class = "dr-link-btn", onclick = "drSetPage('analytics')",
             "View full comparison →")
    )
  })

  # ---- Analytics page: every outlet, for the currently selected location ----
  output$dr_analytics_body <- renderUI({
    click <- input$map_click
    if (is.null(click)) {
      return(tags$div(class = "dr-select-hint", "Select a location on the map to see the delivery comparison."))
    }

    res <- result()

    if (!identical(res$status, "ok")) {
      msg <- switch(res$status,
        "outside_service_area" = "This location is outside the service area.",
        "hostel_curfew"        = "Hostel curfew is active for this location.",
        "no_outlet_reachable"  = "No outlet can currently reach this location.",
        "Delivery unavailable."
      )
      return(tags$div(class = "dr-select-hint", msg))
    }

    rows <- res$all_scores %>% dplyr::arrange(expected_time_min)

    tags$table(class = "dr-table",
      tags$thead(tags$tr(
        tags$th("Outlet"), tags$th("Travel"), tags$th("Queue"),
        tags$th("Live boost"), tags$th("Expected"), tags$th("Status")
      )),
      tags$tbody(
        lapply(seq_len(nrow(rows)), function(i) {
          r <- rows[i, ]
          is_best <- identical(r$outlet_id, res$chosen_outlet)
          tags$tr(
            class = if (is_best) "dr-row-best" else NULL,
            tags$td(r$outlet_id),
            tags$td(sprintf("%.1f min", r$travel_time_min)),
            tags$td(sprintf("%.1f", r$predicted_queue)),
            tags$td(sprintf("%.1f", r$live_queue_boost)),
            tags$td(if (is.na(r$expected_time_min)) "—" else sprintf("%.1f min", r$expected_time_min)),
            tags$td(r$status)
          )
        })
      )
    )
  })

  # ---------------------------------------------------------
  # ROUTE
  # ---------------------------------------------------------

  shiny::observe({

    req(input$map_click)

    res <- result()

    leafletProxy("map") %>%
      clearGroup("route") %>%
      clearGroup("best_outlet")

    if (
      identical(res$status, "ok") &&
      !is.null(res$route_line_projected)
    ) {

      route_ll <- st_transform(
        res$route_line_projected,
        4326
      )

      best_outlet_ll <- outlets_ll %>%
        dplyr::filter(outlet_id == res$chosen_outlet)
      best_outlet_label <- paste0("Best outlet: ", res$chosen_outlet)

      leafletProxy("map") %>%
        addPolylines(
          data = route_ll,
          color = "#1C7293",
          weight = 5,
          label = best_outlet_label,
          group = "route"
        ) %>%
        addAwesomeMarkers(
          data = best_outlet_ll,
          icon = makeAwesomeIcon(
            icon = "location-arrow",
            library = "fa",
            markerColor = "blue",
            iconColor = "white"
          ),
          label = best_outlet_label,
          labelOptions = labelOptions(
            noHide = TRUE,
            direction = "top",
            textOnly = TRUE
          ),
          group = "best_outlet"
        )
    }
  })

  # ---------------------------------------------------------
  # HEATMAP
  # ---------------------------------------------------------

  shiny::observe({

    if (
      isTRUE(input$show_heatmap) &&
      !is.null(order_coords)
    ) {

      leafletProxy("map") %>%
        clearGroup("heatmap") %>%
          addHeatmap(
  data = order_coords, lng = ~lon, lat = ~lat,
  radius = 25, blur = 20, max = 0.6,
  gradient = c("0.2" = "#0000FF", "0.4" = "#00FFFF", "0.6" = "#7FFF00", "0.8" = "#FFFF00", "1.0" = "#FF0000"),
  group = "heatmap"
)

    } else {

      leafletProxy("map") %>%
        clearGroup("heatmap")
    }
  })

  # ---------------------------------------------------------
  # TRAFFIC
  # ---------------------------------------------------------

  output$traffic_text <- renderText({

    t <- get_traffic_state(input$hour)

    sprintf(
      "Traffic: %s (factor %.2f)",
      t$level,
      t$factor
    )
  })

  # ---------------------------------------------------------
  # WEATHER
  # ---------------------------------------------------------

  output$weather_text <- renderText({

    w <- get_weather_state()

    sprintf(
      "Weather: %s (factor %.2f, %s)",
      w$condition,
      w$factor,
      w$source
    )
  })

  # ---------------------------------------------------------
  # CUSTOMER
  # ---------------------------------------------------------

  output$customer_text <- renderPrint({

    click <- input$map_click

    if (is.null(click)) {

      cat("No customer selected yet.")

      return(invisible())
    }

    cat(
      sprintf(
        "lon = %.5f, lat = %.5f\n",
        click$lng,
        click$lat
      )
    )

    res <- result()

    status_msg <- switch(
      res$status,

      "outside_service_area" =
        "Delivery unavailable: customer is outside the service area.",

      "hostel_curfew" =
        "Delivery unavailable: hostel curfew is active.",

      "no_outlet_reachable" =
        "No outlet can currently reach this location.",

      "ok" =
        "Valid service area.",

      "Unknown status."
    )

    cat(status_msg)
  })

  # ---------------------------------------------------------
  # BEST OUTLET
  # ---------------------------------------------------------

  output$best_outlet_text <- renderPrint({

    req(input$map_click)

    res <- result()

    if (!identical(res$status, "ok")) {

      if (identical(res$status, "outside_service_area")) {
        cat("Delivery unavailable: customer is outside the service area.")
      }

      else if (identical(res$status, "hostel_curfew")) {
        cat("Delivery unavailable: hostel curfew is active.")
      }

      else if (identical(res$status, "no_outlet_reachable")) {
        cat("No outlet can currently reach this location.")
      }

      else {
        cat("Delivery unavailable.")
      }

      return(invisible())
    }

    cat(
      sprintf(
        "Best Outlet: %s\n",
        res$chosen_outlet
      )
    )

    cat(
      sprintf(
        "Expected Time: %.1f min\n\n",
        res$expected_time_min
      )
    )

    cat(
      sprintf(
        "Travel: %.1f min\n",
        res$travel_time_min
      )
    )

    cat(
      sprintf(
        "Queue: %.1f orders (model) + %.1f (live)\n",
        res$predicted_queue,
        res$live_queue_boost
      )
    )

    cat(
      sprintf(
        "Prep contribution: %.1f min\n",
        res$prep_contribution_min
      )
    )

    cat(
      sprintf(
        "Traffic factor: %.2f\n",
        res$traffic$factor
      )
    )

    cat(
      sprintf(
        "Weather factor: %.2f\n",
        res$weather$factor
      )
    ) 
  })

  # ---------------------------------------------------------
  # OUTLET COMPARISON
  # ---------------------------------------------------------

  output$comparison_table <- renderTable({

    req(input$map_click)

    res <- result()

    if (!identical(res$status, "ok")) {
      return(NULL)
    }

    res$all_scores
  })

  # ---------------------------------------------------------
  # NETWORK STATUS
  # ---------------------------------------------------------

  output$network_status_table <- renderTable({

    t <- get_traffic_state(input$hour)
    w <- get_weather_state()

    tibble::tibble(

      Metric = c(
        "Traffic factor",
        "Weather factor",
        "Hostel curfew active"
      ),

      Value = c(

        sprintf(
          "%.2f (%s)",
          t$factor,
          t$level
        ),

        sprintf(
          "%.2f (%s)",
          w$factor,
          w$condition
        ),

        if (
          input$hour >= hostel_node$curfew_hour
        ) {
          "Yes"
        } else {
          "No"
        }
      )
    )
  })

  # ---------------------------------------------------------
  # LIVE STREAM
  # ---------------------------------------------------------

  output$live_stream_text <- renderText({

    live <- live_state()

    if (!isTRUE(live$available)) {

      return(
        "Streaming layer offline — using demand model."
      )
    }

    sprintf(
      "Orders processed: %d | New recently: %d",
      live$summary$orders_processed,
      live$summary$recent_orders
    )
  })

  # ---------------------------------------------------------
  # DEBUG PANEL
  # ---------------------------------------------------------

  output$debug_panel <- renderPrint({

    click <- input$map_click

    if (is.null(click)) {

      cat("No customer selected yet.")

      return(invisible())
    }

    pt <- st_sfc(
      st_point(
        c(click$lng, click$lat)
      ),
      crs = 4326
    )

    coords <- st_coordinates(pt)

    cat(
      sprintf(
        "Customer coordinates: lon=%.5f, lat=%.5f\n",
        coords[1],
        coords[2]
      )
    )

    pt_net <- st_transform(
      pt,
      st_crs(city_network)
    )

    nodes_sf <- city_network %>%
      activate("nodes") %>%
      st_as_sf()

    nearest_idx <- st_nearest_feature(
      pt_net,
      nodes_sf
    )

    dist_m <- as.numeric(
      st_distance(
        pt_net,
        nodes_sf[nearest_idx, ]
      )
    )

    cat(
      sprintf(
        "Nearest network node: #%d, %.0f m away\n",
        nearest_idx,
        dist_m
      )
    )

    res <- result()

    inside <- !identical(
      res$status,
      "outside_service_area"
    )

    cat(
      sprintf(
        "Customer inside service area: %s\n",
        if (inside) "YES" else "NO"
      )
    )

    if (identical(res$status, "ok")) {

      cat(
        sprintf(
          "Selected outlet: %s\n",
          res$chosen_outlet
        )
      )

      cat(
        sprintf(
          "Route found: YES (%d edges)\n",
          res$route_edge_count
        )
      )

    } else {

      cat(
        sprintf(
          "Status: %s\n",
          res$status
        )
      )
    }

    t <- get_traffic_state(
      input$hour
    )

    w <- get_weather_state()

    cat(
      sprintf(
        "Current hour: %d\n",
        input$hour
      )
    )

    cat(
      sprintf(
        "Traffic factor: %.2f\n",
        t$factor
      )
    )

    cat(
      sprintf(
        "Weather factor: %.2f\n",
        w$factor
      )
    )
  })
}

shinyApp(ui, server)
