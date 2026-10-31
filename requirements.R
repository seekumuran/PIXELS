# LastMile dependency installer
# Run from the project root: source("requirements.R")

pkgs <- c(
  "osmdata", "sf", "sfnetworks", "tidygraph", "tidymodels",
  "dbscan", "dplyr", "purrr", "lubridate", "shiny", "leaflet",
  "leaflet.extras", "DBI", "RPostgres", "httr", "jsonlite",
  "tibble", "igraph", "ggplot2", "DT", "plotly", "readr", "tidyr"
)

installed <- rownames(installed.packages())
to_install <- setdiff(pkgs, installed)

if (length(to_install) > 0) {
  install.packages(to_install, dependencies = TRUE)
} else {
  message("All required packages are already installed.")
}
