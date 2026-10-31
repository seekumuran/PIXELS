# LastMile DA3: Reproducibility and Testing

## Scope and evidence labels

The project uses OpenStreetMap road geometry for the road graph. Orders and outlet
locations are simulated. Traffic is currently a deterministic hour-of-day model;
weather attempts Open-Meteo and falls back to a simulated condition when unavailable.
The Kafka-compatible Redpanda/PostgreSQL layer is optional. Do not describe synthetic
traffic or simulated orders as live operational data.

## Clean setup

Run commands from the repository root.

```r
source("requirements.R")
```

Build a fast, reproducible synthetic network and all dependent artifacts:

```sh
Rscript run_pipeline.R --fast
```

For the real Chennai road network (internet required):

```sh
Rscript run_pipeline.R
```

Launch the primary dashboard:

```r
shiny::runApp("app_v2.R")
```

## DA3 routing benchmark

After the pipeline completes:

```sh
Rscript experiments/run_benchmarks.R
```

The benchmark uses a fixed seed and the same sampled customer nodes/hours for
all four strategies. It writes:

- `experiments/results/routing_trial_results.csv`
- `experiments/results/routing_strategy_summary.csv`
- `experiments/results/paired_comparisons.csv`

The paired comparison reports mean/median difference, a 95% t confidence interval
and paired t-test p-value against the static baseline. Interpret p-values cautiously:
the experiment is simulation-based, and repeated sampled trials are not independent
real-world deliveries.

## Minimum acceptance checks

1. Pipeline finishes without error and creates the four required `.rds` artifacts.
2. Dashboard starts with `shiny::runApp("app_v2.R")`.
3. Map loads and a click produces an outlet comparison.
4. At least one route is returned for an in-service-area location.
5. Curfew and outside-service-area cases return explicit statuses.
6. Benchmark produces all three CSV result files.
7. When Docker streaming is stopped, dashboard still runs in fallback mode.
8. If streaming is enabled, producer events appear in PostgreSQL and change the live queue count.

## Limitations to state in the report

- Orders are generated synthetically, not collected from a logistics operator.
- Traffic is a time-of-day proxy, not a live traffic feed.
- Weather is live only when the Open-Meteo request succeeds; otherwise fallback data is used.
- Outlet preparation times and queue observations are simulated.
- Benchmark outcomes are simulation results and do not establish real-world delivery savings.
