# LastMile — DA3 Final Report

> **IMPORTANT:** Populate all result tables from `experiments/results/` after running
> the benchmark. Do not insert assumed or fabricated performance values.

## 1. Abstract
LastMile is a geospatial logistics decision-support prototype that ranks fulfilment
outlets using road-network travel time, time-dependent traffic factors, weather
multipliers and predicted queue-related preparation delay. This DA3 stage evaluates
the routing strategies under controlled simulation scenarios and presents results
through an interactive Shiny/Leaflet dashboard.

## 2. Problem statement and objectives
The nearest-outlet heuristic can ignore road travel time and outlet workload.
The project investigates whether adding dynamic conditions and queue estimates
changes outlet selection and estimated fulfilment time.

Objectives:
- Construct a routable spatial graph from OpenStreetMap or the synthetic development graph.
- Estimate outlet queue demand by hour.
- Reweight roads under traffic and weather conditions.
- Rank candidate outlets by estimated total fulfilment time.
- Evaluate routing strategies under identical simulated requests.

## 3. System architecture
Describe the network builder, order simulator, demand model, dynamic scoring engine,
geofence/curfew constraints, optional streaming database and Shiny dashboard.
Include the architecture diagram from README and screenshots from the running app.

## 4. Dataset and preprocessing
State clearly that orders, outlets and queue observations are simulated. Document
the generated sample size from the actual run, feature definitions, random seed,
and any excluded/invalid route cases.

## 5. Methodology
Describe the four benchmark strategies in `experiments/run_benchmarks.R`.
All strategies share sampled customer nodes and request hours. Explain how route
travel time and predicted queue/preparation time contribute to the score.

## 6. Experimental results
Insert the generated summary and paired-comparison CSV tables here.
Report trial count, successful routes, mean/median/P95 route time, estimated total
time, confidence intervals and paired-test p-values. Explain missing values and
failed routes rather than silently dropping them.

## 7. Dashboard
Document the actual controls, map layers, outlet comparison and live-stream status
visible in the submitted running version. Include genuine screenshots.

## 8. Discussion
Interpret which strategy performs best in the tested simulation, whether differences
are consistent, how queue-aware ranking changes outlet choice, and the trade-off
between additional computation and estimated fulfilment time. Do not generalize
simulation results to real-world operations.

## 9. Limitations
- Synthetic order arrivals, outlet positions and queue labels.
- Traffic represented by an hour-based proxy rather than a live traffic feed.
- Weather may use a fallback condition when the API is unavailable.
- Simplified preparation-time assumptions.
- Simulation-based benchmark does not establish operational delivery savings.

## 10. Conclusion and future work
Summarize only findings supported by the generated benchmark. Future work may include
validated historical order data, a licensed live traffic source, carrier-specific
travel times, calibrated queue prediction, deployment monitoring and larger-scale
stress tests.

## References and acknowledgements
Cite OpenStreetMap and its applicable attribution requirements, Open-Meteo, and
the R/Python packages and upstream repositories actually used. Verify licenses
before redistribution.
