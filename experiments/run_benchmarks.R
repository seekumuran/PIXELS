# DA3: reproducible routing strategy benchmark
# Run AFTER: Rscript run_pipeline.R --fast
# Then: Rscript experiments/run_benchmarks.R
#
# Strategies use identical sampled customer nodes and hours:
# 1) static shortest-time: base road travel time only
# 2) traffic-aware: base time x traffic factor
# 3) traffic+weather: base time x traffic x weather
# 4) full LastMile: traffic+weather plus predicted queue/preparation time
#
# Weather values may be live or fallback. The output records the source.
# This benchmark does not claim live traffic: traffic is the project's
# hour-based synthetic traffic model.

suppressPackageStartupMessages({
  library(sf)
  library(sfnetworks)
  library(tidygraph)
  library(dplyr)
  library(purrr)
  library(tibble)
  library(readr)
})

required <- c("city_network.rds", "outlets.rds", "hostel_node.rds", "demand_model.rds")
missing <- required[!file.exists(required)]
if (length(missing)) {
  stop("Missing generated files: ", paste(missing, collapse=", "),
       ". Run Rscript run_pipeline.R --fast first.")
}

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")
source("R/08_dynamic_scoring_v2.R")

network <- readRDS("city_network.rds")
outlets <- readRDS("outlets.rds")
hostel <- readRDS("hostel_node.rds")
model <- readRDS("demand_model.rds")
nodes <- network %>% activate("nodes") %>% st_as_sf()

set.seed(2026)
n_trials <- 100L
trial_nodes <- sample(seq_len(nrow(nodes)), n_trials, replace = TRUE)
trial_hours <- sample(8:22, n_trials, replace = TRUE)

route_time <- function(net, from_geom, to_geom, weight_col) {
  p <- tryCatch(
    sfnetworks::st_network_paths(net, from=from_geom, to=to_geom, weights=weight_col),
    error=function(e) NULL
  )
  if (is.null(p) || !length(p$edge_paths[[1]])) return(Inf)
  es <- net %>% activate("edges") %>% st_as_sf()
  sum(es[[weight_col]][p$edge_paths[[1]]], na.rm=TRUE)
}

run_one <- function(i) {
  customer <- st_transform(nodes[trial_nodes[i], ], st_crs(network))
  hour <- trial_hours[i]
  traffic <- get_traffic_state(hour, add_jitter=FALSE)
  weather <- get_weather_state()
  base <- network %>% activate("edges") %>% mutate(
    static_time = travel_time_min,
    traffic_time = travel_time_min * traffic$factor,
    traffic_weather_time = travel_time_min * traffic$factor * weather$factor
  )

  scored <- lapply(seq_len(nrow(outlets)), function(j) {
    outlet <- outlets[j,]
    q <- tryCatch(as.numeric(predict(model,
       tibble(outlet_id=outlet$outlet_id, hour=hour))$.pred), error=function(e) 2)
    q <- max(0, q)
    prep <- outlet$avg_prep_time_min

    t_static <- route_time(base, outlet$geometry, customer$geometry, "static_time")
    t_traffic <- route_time(base, outlet$geometry, customer$geometry, "traffic_time")
    t_weather <- route_time(base, outlet$geometry, customer$geometry, "traffic_weather_time")

    tibble(outlet_id=outlet$outlet_id, queue=q, prep=prep,
           static_travel=t_static, traffic_travel=t_traffic,
           weather_travel=t_weather,
           static_score=t_static,
           traffic_score=t_traffic,
           weather_score=t_weather,
           full_score=t_weather + q*prep)
  }) %>% bind_rows()

  strategies <- c("static","traffic","weather","full")
  map_dfr(strategies, function(strategy) {
    score_col <- paste0(strategy, "_score")
    travel_col <- if (strategy=="static") "static_travel" else if (strategy=="traffic") "traffic_travel" else "weather_travel"
    valid <- scored %>% filter(is.finite(.data[[score_col]]))
    if (!nrow(valid)) {
      return(tibble(trial=i, hour=hour, weather_source=weather$source,
                    strategy=strategy, chosen_outlet=NA_character_,
                    route_time_min=NA_real_, estimated_total_min=NA_real_))
    }
    winner <- valid %>% slice_min(.data[[score_col]], n=1, with_ties=FALSE)
    tibble(trial=i, hour=hour, weather_source=weather$source,
           strategy=strategy, chosen_outlet=winner$outlet_id,
           route_time_min=winner[[travel_col]],
           estimated_total_min=winner[[score_col]])
  })
}

results <- map_dfr(seq_len(n_trials), run_one)
dir.create("experiments/results", recursive=TRUE, showWarnings=FALSE)
readr::write_csv(results, "experiments/results/routing_trial_results.csv")

summary <- results %>%
  group_by(strategy) %>%
  summarise(
    trials=n(),
    successful_trials=sum(is.finite(estimated_total_min), na.rm=TRUE),
    mean_route_time_min=mean(route_time_min, na.rm=TRUE),
    median_route_time_min=median(route_time_min, na.rm=TRUE),
    p95_route_time_min=as.numeric(quantile(route_time_min, .95, na.rm=TRUE)),
    mean_estimated_total_min=mean(estimated_total_min, na.rm=TRUE),
    sd_estimated_total_min=sd(estimated_total_min, na.rm=TRUE),
    .groups="drop"
  )
readr::write_csv(summary, "experiments/results/routing_strategy_summary.csv")
print(summary)

# Paired comparison against static baseline on trials where both succeeded.
paired <- results %>%
  select(trial, strategy, estimated_total_min) %>%
  tidyr::pivot_wider(names_from=strategy, values_from=estimated_total_min)
comparison <- purrr::map_dfr(c("traffic","weather","full"), function(s) {
  d <- paired %>% filter(is.finite(static), is.finite(.data[[s]]))
  delta <- d$static - d[[s]]
  tibble(strategy=s, paired_trials=nrow(d),
         mean_improvement_min=mean(delta),
         median_improvement_min=median(delta),
         improvement_ci_low=if(nrow(d)>1) t.test(delta)$conf.int[1] else NA_real_,
         improvement_ci_high=if(nrow(d)>1) t.test(delta)$conf.int[2] else NA_real_,
         paired_t_test_p=if(nrow(d)>1) t.test(delta)$p.value else NA_real_)
})
readr::write_csv(comparison, "experiments/results/paired_comparisons.csv")
print(comparison)
message("Benchmark complete. Results saved under experiments/results/.")
