# Contributing to LastMile

Thanks for your interest in improving LastMile.

## Before submitting changes
- Keep simulated inputs clearly labelled as simulated.
- Do not describe hour-based traffic multipliers as live traffic.
- Do not commit generated `.rds` files, local databases, credentials, or `.env` files.
- Keep experiment seeds and evaluation procedures reproducible.
- Do not add performance claims unless supported by generated benchmark outputs.

## Development checks
1. Run `source("requirements.R")`.
2. Run `Rscript run_pipeline.R --fast`.
3. Run `Rscript experiments/run_benchmarks.R`.
4. Launch `shiny::runApp("app_v2.R")`.
5. Record any failing checks and environment details in the pull request.

## Pull requests
Describe the problem, the change, how it was tested, and whether it changes
the benchmark methodology or reported results.
