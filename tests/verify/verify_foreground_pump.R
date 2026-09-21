# AUI_FOREGROUND_MODE=slow|quiet|usage; use the bounded browser runner with --timeout 240.
local({
  scope <- new.env(parent = globalenv())
  sys.source("tests/verify/compare_sdk_memory.R", envir = scope)
  mode <- Sys.getenv("AUI_FOREGROUND_MODE", "slow")
  output <- Sys.getenv("AUI_FOREGROUND_OUT", tempfile("foreground-pump-"))
  stopifnot(
    mode %in% c("slow", "quiet", "usage"),
    !identical(Sys.getenv("R_ENABLE_JIT"), "0"),
    identical(
      normalizePath(find.package("shinyAssistantUI")),
      "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
    )
  )
  verify <- function(name, events = 32L, interval = 0.001, quiet = 0,
                     usage_delay = 0, post_done = 0, pss_mib = 300,
                     context_updates = 1L) {
    directory <- file.path(output, name)
    result <- scope$run_sdk_memory_comparison(
      arms = "plugin", events = events, interval = interval,
      output = directory, deep_stack = TRUE,
      timeout = events * interval + quiet + post_done + 45,
      pss_limit_bytes = 512 * 1024^2,
      quiet_seconds = quiet, usage_delay_seconds = usage_delay,
      post_done_seconds = post_done
    )
    details <- readRDS(file.path(directory, "plugin-result.rds"))
    stopifnot(
      result$pss_post_gc_bytes < pss_mib * 1024^2,
      result$done == 1L, result$chunks == events, result$semantic_ok,
      result$console_errors == 0L, result$network_errors == 0L,
      result$cleanup_confirmed,
      details$terminal_snapshot$active_turns == 0L,
      details$handler_snapshot$active_turns == 0L,
      details$handler_snapshot$usage_probes_pending == 0L,
      details$context_updates == context_updates,
      details$usage_updates == 1L + context_updates,
      details$first_chunk_seconds >= quiet,
      details$duration_seconds >= quiet + (events - 1L) * interval,
      details$observation_seconds >= details$duration_seconds + post_done
    )
    if (usage_delay > 0) {
      stopifnot(details$terminal_snapshot$usage_probes_pending == 1L)
    }
    cat("[PASS] ", name, ": installed pump, single terminal, bounded memory and cleanup\n",
        sep = "")
    result
  }
  if (mode == "slow") {
    small <- verify("slow-600", events = 600L, interval = 0.1)
    large <- verify("slow-1200", events = 1200L, interval = 0.1, pss_mib = 350)
    stopifnot(large$pss_post_gc_bytes - small$pss_post_gc_bytes < 64 * 1024^2)
  } else if (mode == "quiet") {
    verify("quiet-delayed-usage", quiet = 60, usage_delay = 5, post_done = 6)
  } else {
    verify("usage-after-deadline", usage_delay = 35, post_done = 37, context_updates = 0L)
    verify("usage-no-reply", usage_delay = Inf, post_done = 32, context_updates = 0L)
  }
  cat("FOREGROUND_PUMP_GATES_PASSED mode=", mode, "\n", sep = "")
})
