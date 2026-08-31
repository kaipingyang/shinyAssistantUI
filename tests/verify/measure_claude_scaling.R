#!/usr/bin/env Rscript

# Opt-in real-client scaling baseline. Safe by default: without --run it only
# prints usage and never starts Claude CLI processes.
args <- commandArgs(trailingOnly = TRUE)
if (!"--run" %in% args) {
  cat(paste0(
    "Usage: Rscript tests/verify/measure_claude_scaling.R --run ",
    "[--threads=1,5,10,25] [--seconds=5]\n",
    "This explicitly starts real Claude CLI clients (up to 25) and reports only ",
    "aggregate CPU/RSS/poll/heartbeat metrics.\n"
  ))
  quit(status = 0L)
}

option_value <- function(prefix, default) {
  hit <- args[startsWith(args, paste0(prefix, "="))]
  if (!length(hit)) return(default)
  sub(paste0("^", prefix, "="), "", hit[[1L]])
}
levels <- sort(unique(as.integer(strsplit(
  option_value("--threads", "1,5,10,25"), ",", fixed = TRUE
)[[1L]])))
seconds <- as.numeric(option_value("--seconds", "5"))
if (!length(levels) || anyNA(levels) || any(levels < 1L) || any(levels > 25L)) {
  stop("--threads must contain integers from 1 through 25", call. = FALSE)
}
if (length(seconds) != 1L || !is.finite(seconds) || seconds < 1 || seconds > 60) {
  stop("--seconds must be between 1 and 60", call. = FALSE)
}

suppressPackageStartupMessages({
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
  library(later)
})

handler <- make_claude_handler(
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd = tempdir(),
    permission_mode = "bypassPermissions",
    include_partial_messages = TRUE
  ),
  session_map_path = tempfile("claude-scaling-", fileext = ".rds")
)
on.exit(attr(handler, "cleanup")(), add = TRUE)
snapshot <- attr(handler, "performance_snapshot")
stopifnot(is.function(snapshot))

proc_metrics <- function() {
  if (!requireNamespace("ps", quietly = TRUE)) {
    return(list(rss_mb = NA_real_, cpu_seconds = NA_real_, descendants = NA_integer_, claude_descendants = NA_integer_))
  }
  self <- ps::ps_handle()
  memory <- ps::ps_memory_info(self)
  cpu <- ps::ps_cpu_times(self)
  children <- tryCatch(ps::ps_children(self, recursive = TRUE), error = function(error) list())
  names <- vapply(children, function(child) {
    tryCatch(ps::ps_name(child), error = function(error) "")
  }, character(1))
  list(
    rss_mb = unname(memory[["rss"]]) / 1024^2,
    cpu_seconds = unname(cpu[["user"]] + cpu[["system"]]),
    descendants = length(children),
    claude_descendants = sum(grepl("claude|node", names, ignore.case = TRUE))
  )
}

poll_totals <- function(value) {
  metrics <- lapply(value$threads, `[[`, "coordinator")
  metrics <- Filter(Negate(is.null), metrics)
  list(
    idle = sum(vapply(metrics, `[[`, numeric(1), "idle_polls")),
    empty = sum(vapply(metrics, `[[`, numeric(1), "empty_idle_polls"))
  )
}

sample_window <- function(duration) {
  beats <- numeric()
  last <- proc.time()[["elapsed"]]
  active <- TRUE
  beat <- function() {
    if (!active) return(invisible(NULL))
    now <- proc.time()[["elapsed"]]
    beats <<- c(beats, now - last)
    last <<- now
    later::later(beat, delay = 0.1)
  }
  later::later(beat, delay = 0.1)
  deadline <- proc.time()[["elapsed"]] + duration
  while (proc.time()[["elapsed"]] < deadline) later::run_now(0.05)
  active <- FALSE
  later::run_now(0)
  drift <- if (length(beats)) pmax(0, beats - 0.1) else NA_real_
  list(
    heartbeat_p95_ms = if (all(is.na(drift))) NA_real_ else unname(stats::quantile(drift * 1000, 0.95, na.rm = TRUE)),
    heartbeat_max_ms = if (all(is.na(drift))) NA_real_ else max(drift * 1000, na.rm = TRUE)
  )
}

rows <- list()
warmed <- 0L
for (target in levels) {
  if (target > warmed) {
    for (index in seq.int(warmed + 1L, target)) {
      attr(handler, "warmup")(sprintf("perf-thread-%02d", index), tempdir())
    }
    warmed <- target
  }
  # Let initial server/control frames settle before measuring steady idle work.
  settle_deadline <- proc.time()[["elapsed"]] + 1
  while (proc.time()[["elapsed"]] < settle_deadline) later::run_now(0.05)

  before_snapshot <- snapshot()
  before_polls <- poll_totals(before_snapshot)
  before_proc <- proc_metrics()
  heartbeat <- sample_window(seconds)
  after_snapshot <- snapshot()
  after_polls <- poll_totals(after_snapshot)
  after_proc <- proc_metrics()

  rows[[length(rows) + 1L]] <- data.frame(
    threads = target,
    sample_seconds = seconds,
    connected_clients = after_snapshot$connected_clients,
    coordinators = after_snapshot$coordinators,
    idle_polls_per_second = (after_polls$idle - before_polls$idle) / seconds,
    empty_idle_polls_per_second = (after_polls$empty - before_polls$empty) / seconds,
    r_cpu_seconds = after_proc$cpu_seconds - before_proc$cpu_seconds,
    r_rss_mb = after_proc$rss_mb,
    descendants = after_proc$descendants,
    claude_descendants = after_proc$claude_descendants,
    heartbeat_p95_ms = heartbeat$heartbeat_p95_ms,
    heartbeat_max_ms = heartbeat$heartbeat_max_ms
  )
}

write.csv(do.call(rbind, rows), stdout(), row.names = FALSE, na = "")
