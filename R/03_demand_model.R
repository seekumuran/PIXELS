# 03_demand_model.R
#
# Trains a simple model that predicts expected queue length for an outlet
# given the hour of day. Kept deliberately simple (easy to explain in a
# viva) — swap in a fancier tidymodels spec (random forest, xgboost, etc.)
# as a drop-in replacement if you want more accuracy.

library(tidymodels)
library(dplyr)

orders <- readRDS("simulated_orders.rds")

# ---- 1. Aggregate to one row per outlet-hour -------------------------------
queue_by_hour <- orders %>%
  group_by(outlet_id, hour) %>%
  summarise(
    avg_queue_length = mean(queue_length_at_order),
    n_orders = n(),
    .groups = "drop"
  )

# ---- 2. Train/test split ---------------------------------------------------
set.seed(42)
split <- initial_split(queue_by_hour, prop = 0.8)
train_data <- training(split)
test_data  <- testing(split)

# ---- 3. Model spec: simple linear model on hour + outlet ------------------
queue_recipe <- recipe(avg_queue_length ~ hour + outlet_id, data = train_data) %>%
  step_dummy(outlet_id)

queue_model <- linear_reg() %>%
  set_engine("lm")

queue_workflow <- workflow() %>%
  add_recipe(queue_recipe) %>%
  add_model(queue_model)

queue_fit <- fit(queue_workflow, data = train_data)

# ---- 4. Quick sanity check on held-out data --------------------------------
preds <- predict(queue_fit, test_data) %>%
  bind_cols(test_data)

metrics <- metric_set(rmse, mae)
perf <- metrics(preds, truth = avg_queue_length, estimate = .pred)
print(perf)

# ---- 5. Save the fitted model ----------------------------------------------
saveRDS(queue_fit, "demand_model.rds")
message("Demand model trained and saved to demand_model.rds")

# ---- Helper used later by the scoring step ---------------------------------
# Predicts expected queue length for a given outlet at a given hour.
# Falls back to a small default if the outlet/hour combo wasn't seen in training.
predict_queue_length <- function(model, outlet_id, hour) {
  new_data <- tibble(outlet_id = outlet_id, hour = hour)
  pred <- tryCatch(
    predict(model, new_data)$.pred,
    error = function(e) 2  # conservative fallback
  )
  pmax(pred, 0)
}
