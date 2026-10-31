# R/00_predict_helpers.R
#
# Small standalone helper used by both 03_demand_model.R (at training time)
# and 04_dynamic_scoring.R (at scoring time). Split out on its own so that
# scoring an order doesn't require re-running the full model training
# pipeline just to get this one function.

# Predicts expected queue length for a given outlet at a given hour.
# Falls back to a small default if the outlet/hour combo wasn't seen in training.
predict_queue_length <- function(model, outlet_id, hour) {
  new_data <- tibble::tibble(outlet_id = outlet_id, hour = hour)
  pred <- tryCatch(
    predict(model, new_data)$.pred,
    error = function(e) 2  # conservative fallback
  )
  pmax(pred, 0)
}
