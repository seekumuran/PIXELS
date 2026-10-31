# R/06_conditions.R
#
# "Current conditions" that make the graph dynamic: synthetic traffic
# (driven by hour of day) and live weather (Open-Meteo, no API key, safe
# fallback if unreachable). Both return a multiplier that scales an edge's
# base travel time -- this is what makes the SAME road network produce
# different travel times at different moments.

library(httr)
library(jsonlite)

# ---- Configurable constants (single source of truth) -----------------------
TRAFFIC_FACTORS <- c(Low = 1.00, Moderate = 1.10, High = 1.20, "Very High" = 1.30)
WEATHER_FACTORS <- c(Clear = 1.00, Cloudy = 1.05, "Light Rain" = 1.15, "Heavy Rain" = 1.30)

DEFAULT_WEATHER_LAT <- 13.0827
DEFAULT_WEATHER_LON <- 80.2707

# ---- Traffic ----------------------------------------------------------------
get_traffic_state <- function(hour, add_jitter = TRUE) {
  level <- if (hour >= 0 && hour <= 5) {
    "Low"
  } else if (hour >= 6 && hour <= 8) {
    "Moderate"
  } else if (hour >= 9 && hour <= 16) {
    "Moderate"
  } else if (hour >= 17 && hour <= 20) {
    "Very High"
  } else {
    "Moderate"  # 21-23
  }

  factor <- unname(TRAFFIC_FACTORS[level])
  if (add_jitter) {
    factor <- factor + runif(1, -0.02, 0.02)
  }

  list(level = level, factor = factor)
}

# ---- Weather ------------------------------------------------------------
map_weather_code <- function(code) {
  if (code == 0) return("Clear")
  if (code %in% c(1, 2, 3)) return("Cloudy")
  if (code %in% c(51, 53, 55, 61, 63, 80)) return("Light Rain")
  if (code %in% c(65, 66, 67, 82, 95, 96, 99)) return("Heavy Rain")
  "Cloudy"
}

get_weather_state <- function(lat = DEFAULT_WEATHER_LAT, lon = DEFAULT_WEATHER_LON) {
  result <- tryCatch({
    url <- sprintf(
      "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current_weather=true",
      lat, lon
    )
    resp <- httr::GET(url, httr::timeout(5))
    if (httr::status_code(resp) != 200) stop("non-200 response")

    parsed <- jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"))
    code <- parsed$current_weather$weathercode
    condition <- map_weather_code(code)

    list(condition = condition, factor = unname(WEATHER_FACTORS[condition]), source = "live")
  }, error = function(e) {
    condition <- sample(names(WEATHER_FACTORS), 1, prob = c(0.55, 0.25, 0.15, 0.05))
    list(condition = condition, factor = unname(WEATHER_FACTORS[condition]), source = "fallback")
  })

  result
}
