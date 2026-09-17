#!/usr/bin/env Rscript

required <- c(
  PLAN123_SHARD_MODE = "mode",
  PLAN123_SHARD_START = "start",
  PLAN123_SHARD_COUNT = "count",
  PLAN123_SHARD_SEED = "seed",
  PLAN123_SHARD_ARTIFACT = "artifact"
)
values <- Sys.getenv(names(required), unset = "")
if (any(!nzchar(values))) {
  stop(
    "Missing Plan123 shard environment: ",
    paste(names(required)[!nzchar(values)], collapse = ", "),
    call. = FALSE
  )
}
source("tests/verify/run_plan123_performance_shard.R", local = TRUE)
run_plan123_shard(unname(values))
