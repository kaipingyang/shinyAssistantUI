#!/usr/bin/env Rscript
# Measurement gate, not a nonblocking pass gate: ClaudeAgentSDK 0.2.3 connects
# synchronously. This records the event-loop pause so Plan 67 does not overclaim.
main <- function() {
  if (file.exists(".Renviron")) readRenviron(".Renviron")
  suppressMessages({
    library(shinyAssistantUI)
    library(ClaudeAgentSDK)
    library(later)
  })

  options <- ClaudeAgentSDK::ClaudeAgentOptions(
    cwd = getwd(),
    permission_mode = "bypassPermissions",
    permission_prompt_tool_name = "stdio",
    include_partial_messages = TRUE
  )
  handler <- make_claude_handler(
    options = options,
    session_map_path = tempfile("plan67-cold-map-", fileext = ".rds")
  )
  on.exit(try(attr(handler, "cleanup")(), silent = TRUE), add = TRUE)

  ticks <- numeric()
  alive <- TRUE
  heartbeat <- NULL
  heartbeat <- function() {
    ticks <<- c(ticks, unname(proc.time()[["elapsed"]]))
    if (alive) later::later(heartbeat, 0.05)
  }
  later::later(heartbeat, 0)
  later::run_now(0.15)
  started <- unname(proc.time()[["elapsed"]])
  attr(handler, "warmup")("cold-heartbeat-measure")
  ended <- unname(proc.time()[["elapsed"]])
  later::run_now(0.15)
  alive <- FALSE

  gaps <- if (length(ticks) > 1L) diff(ticks) else numeric()
  connect_seconds <- ended - started
  max_gap <- if (length(gaps)) max(gaps) else NA_real_
  cat(sprintf("cold_connect_seconds=%.3f\n", connect_seconds))
  cat(sprintf("max_heartbeat_gap_seconds=%.3f\n", max_gap))
  cat(sprintf("ticks=%d\n", length(ticks)))
  stopifnot(is.finite(connect_seconds), connect_seconds >= 0,
            is.finite(max_gap), max_gap >= 0, length(ticks) >= 2L)
  cat("PLAN67_COLD_CONNECT_MEASUREMENT_DONE\n")
}

main()
