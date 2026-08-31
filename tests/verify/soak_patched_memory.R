# Long-lived patched-memory soak harness. Test-only; never reads project files.
# Usage: Rscript soak_patched_memory.R <target_cwd> <output_dir> <duration_s>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) stop("Expected: <target_cwd> <output_dir> <duration_s>")
target_cwd <- normalizePath(args[[1L]], mustWork = TRUE)
out_dir <- args[[2L]]
duration_s <- as.numeric(args[[3L]])
stopifnot(is.finite(duration_s), duration_s >= 30)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
setwd(target_cwd)

home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
.libPaths(c(home_lib, .libPaths()))
suppressPackageStartupMessages({
  library(ClaudeAgentSDK)
  library(shinyAssistantUI)
})
sdk_ns <- asNamespace("ClaudeAgentSDK")
aui_ns <- asNamespace("shinyAssistantUI")
new_decoder <- get(".new_stream_line_decoder", sdk_ns)
parse_message <- get("parse_message", sdk_ns)
extract_results <- get(".claude_user_tool_results", aui_ns)
ui_result <- get(".claude_ui_tool_result", aui_ns)
is_oversized <- get(".claude_tool_result_is_oversized", aui_ns)
msgs_to_thread <- get(".claude_msgs_to_thread", aui_ns)
`%||%` <- function(x, y) if (is.null(x)) y else x

metrics_path <- file.path(out_dir, "metrics.csv")
events_path <- file.path(out_dir, "events.log")
status_path <- file.path(out_dir, "status.txt")
writeLines(as.character(Sys.getpid()), file.path(out_dir, "pid"))
writeLines("starting", status_path)

log_event <- function(...) {
  cat(
    format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3%z"), ...,
    "\n", file = events_path, append = TRUE
  )
}

proc_value_kb <- function(name) {
  line <- grep(paste0("^", name, ":"), readLines("/proc/self/status", warn = FALSE), value = TRUE)
  if (!length(line)) return(NA_real_)
  as.numeric(gsub("[^0-9]", "", line[[1L]]))
}
pss_kb <- function() {
  path <- "/proc/self/smaps_rollup"
  if (!file.exists(path)) return(NA_real_)
  line <- grep("^Pss:", readLines(path, warn = FALSE), value = TRUE)
  if (!length(line)) return(NA_real_)
  as.numeric(gsub("[^0-9]", "", line[[1L]]))
}
read_number <- function(path) {
  value <- tryCatch(readLines(path, n = 1L, warn = FALSE), error = function(error) NA_character_)
  suppressWarnings(as.numeric(value[[1L]]))
}
claude_descendants <- function(root_pid) {
  lines <- tryCatch(
    system("ps -eo pid=,ppid=,rss=,comm=", intern = TRUE),
    error = function(error) character()
  )
  if (!length(lines)) return(data.frame())
  fields <- strsplit(trimws(lines), "[[:space:]]+")
  rows <- lapply(fields, function(item) {
    if (length(item) < 4L) return(NULL)
    data.frame(
      pid = suppressWarnings(as.integer(item[[1L]])),
      ppid = suppressWarnings(as.integer(item[[2L]])),
      rss_kb = suppressWarnings(as.numeric(item[[3L]])),
      comm = item[[4L]], stringsAsFactors = FALSE
    )
  })
  table <- do.call(rbind, Filter(Negate(is.null), rows))
  if (is.null(table) || !nrow(table)) return(data.frame())
  descendants <- integer()
  frontier <- as.integer(root_pid)
  repeat {
    children <- table$pid[table$ppid %in% frontier]
    children <- setdiff(children, descendants)
    if (!length(children)) break
    descendants <- c(descendants, children)
    frontier <- children
  }
  table[table$pid %in% descendants & table$comm == "claude", , drop = FALSE]
}

# Build the same capped target-project workspace index once. This touches names
# only through the package's existing capped scanner and never reads file bodies.
workspace_started <- proc.time()[["elapsed"]]
workspace_index <- tryCatch(
  get(".addin_workspace_index", aui_ns)(target_cwd, max_files = 10000L),
  error = function(error) {
    log_event("workspace_index_error", conditionMessage(error))
    NULL
  }
)
workspace_elapsed <- proc.time()[["elapsed"]] - workspace_started
log_event(
  "workspace_index",
  paste0("elapsed_s=", sprintf("%.3f", workspace_elapsed)),
  paste0("entries=", length(workspace_index %||% character()))
)

# Keep one real Claude executable child waiting on stream-json stdin. No prompt,
# project content, or file data is sent. Failure is recorded and soak continues.
Sys.unsetenv("CLAUDECODE")
claude_proc <- tryCatch({
  cli <- ClaudeAgentSDK::find_claude()
  processx::process$new(
    command = cli,
    args = c(
      "--output-format", "stream-json",
      "--input-format", "stream-json",
      "--verbose"
    ),
    stdin = "|",
    stdout = file.path(out_dir, "claude.stdout.log"),
    stderr = file.path(out_dir, "claude.stderr.log"),
    wd = target_cwd,
    cleanup = TRUE
  )
}, error = function(error) {
  log_event("claude_start_error", conditionMessage(error))
  NULL
})
on.exit({
  if (!is.null(claude_proc)) {
    try(if (claude_proc$is_alive()) claude_proc$kill(), silent = TRUE)
  }
}, add = TRUE)
Sys.sleep(1)
if (!is.null(claude_proc) && claude_proc$is_alive()) {
  log_event("claude_started", paste0("pid=", claude_proc$get_pid()))
} else {
  log_event("claude_not_running")
  claude_proc <- NULL
}

gc_count <- 0L
gc_total_s <- 0
gc_max_s <- 0
gc_last_s <- 0
tool_events <- 0L
original_bytes_total <- 0
preview_bytes_total <- 0
ui_ring <- list()
last_mode <- "baseline"

run_full_gc <- function() {
  timing <- system.time(invisible(gc(full = TRUE)))
  elapsed <- unname(timing[["elapsed"]])
  gc_count <<- gc_count + 1L
  gc_total_s <<- gc_total_s + elapsed
  gc_max_s <<- max(gc_max_s, elapsed)
  gc_last_s <<- elapsed
  elapsed
}

feed_json <- function(json) {
  decoder <- new_decoder()
  total <- nchar(json, type = "chars")
  starts <- seq.int(1L, total, by = 1024L * 1024L)
  lines <- character()
  for (start in starts) {
    end <- min(total, start + 1024L * 1024L - 1L)
    lines <- c(lines, decoder$feed(substr(json, start, end)))
  }
  lines <- c(lines, decoder$feed("\n"))
  stopifnot(length(lines) == 1L)
  lines[[1L]]
}

record_preview <- function(preview, original_bytes) {
  wire <- as.character(jsonlite::toJSON(preview, auto_unbox = TRUE, null = "null"))
  tool_events <<- tool_events + 1L
  original_bytes_total <<- original_bytes_total + original_bytes
  preview_bytes_total <<- preview_bytes_total + nchar(wire, type = "bytes")
  ui_ring[[length(ui_ring) + 1L]] <<- preview
  if (length(ui_ring) > 20L) ui_ring <<- utils::tail(ui_ring, 20L)
  invisible(NULL)
}

run_user_result <- function(result, id) {
  block_content <- if (is.character(result)) result else "structured result"
  payload <- list(
    type = "user", uuid = paste0("soak-", id), session_id = "soak-session",
    message = list(
      role = "user",
      content = list(list(
        type = "tool_result", tool_use_id = paste0("tool-", id),
        content = block_content, is_error = FALSE
      ))
    ),
    tool_use_result = result
  )
  json <- as.character(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"))
  original_bytes <- nchar(json, type = "bytes")
  line <- feed_json(json)
  message <- parse_message(line)
  results <- extract_results(message)
  stopifnot(length(results) == 1L)
  original <- results[[1L]]$result
  oversized <- is_oversized(original)
  preview <- ui_result(original)
  record_preview(preview, original_bytes)
  payload <- json <- line <- message <- results <- original <- preview <- NULL
  if (oversized) run_full_gc()
  invisible(NULL)
}

run_history_result <- function(text, id) {
  raw_messages <- list(
    list(
      type = "user", uuid = paste0("history-result-", id),
      message = list(content = list(list(
        type = "tool_result", tool_use_id = paste0("history-tool-", id),
        content = text, is_error = FALSE
      )))
    ),
    list(
      type = "assistant", uuid = paste0("history-call-", id),
      message = list(content = list(list(
        type = "tool_use", id = paste0("history-tool-", id), name = "Bash",
        input = list(command = "synthetic-soak")
      )))
    )
  )
  thread <- msgs_to_thread(raw_messages)
  preview <- thread[[1L]]$content[[1L]]$result
  record_preview(preview, nchar(text, type = "bytes"))
  raw_messages <- thread <- preview <- text <- NULL
  run_full_gc()
  invisible(NULL)
}

metric_columns <- c(
  "timestamp", "elapsed_s", "epoch", "mode", "rss_kb", "pss_kb", "vmsize_kb",
  "claude_count", "claude_rss_kb", "claude_max_rss_kb", "cgroup_current",
  "cgroup_max", "tool_events", "original_bytes_total", "preview_bytes_total",
  "gc_count", "gc_total_s", "gc_max_s", "gc_last_s", "workspace_entries"
)
writeLines(paste(metric_columns, collapse = ","), metrics_path)

start_time <- Sys.time()
next_sample <- 0
next_workload <- 10
cycle <- 0L
writeLines("running", status_path)
log_event("soak_started", paste0("pid=", Sys.getpid()), paste0("duration_s=", duration_s))

repeat {
  elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
  if (elapsed >= duration_s || file.exists(file.path(out_dir, "STOP"))) break

  if (elapsed >= next_workload) {
    cycle <- cycle + 1L
    mode_index <- ((cycle - 1L) %% 4L) + 1L
    if (mode_index == 1L) {
      last_mode <- "small"
      run_user_result(strrep("s", 32L * 1024L), cycle)
    } else if (mode_index == 2L) {
      last_mode <- "large_text"
      run_user_result(strrep("L", 8L * 1024L * 1024L), cycle)
    } else if (mode_index == 3L) {
      last_mode <- "structured"
      run_user_result(list(values = rep(.Machine$integer.max, 100000L)), cycle)
    } else {
      last_mode <- "history"
      run_history_result(strrep("H", 8L * 1024L * 1024L), cycle)
    }
    next_workload <- elapsed + 20
  }

  if (elapsed >= next_sample) {
    children <- claude_descendants(Sys.getpid())
    claude_count <- if (nrow(children)) nrow(children) else 0L
    claude_rss <- if (nrow(children)) sum(children$rss_kb) else 0
    claude_max <- if (nrow(children)) max(children$rss_kb) else 0
    values <- c(
      format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3%z"),
      sprintf("%.3f", elapsed),
      as.character(floor(elapsed / 600) + 1L),
      last_mode,
      as.character(proc_value_kb("VmRSS")),
      as.character(pss_kb()),
      as.character(proc_value_kb("VmSize")),
      as.character(claude_count),
      as.character(claude_rss),
      as.character(claude_max),
      as.character(read_number("/sys/fs/cgroup/memory.current")),
      as.character(read_number("/sys/fs/cgroup/memory.max")),
      as.character(tool_events),
      as.character(original_bytes_total),
      as.character(preview_bytes_total),
      as.character(gc_count),
      sprintf("%.6f", gc_total_s),
      sprintf("%.6f", gc_max_s),
      sprintf("%.6f", gc_last_s),
      as.character(length(workspace_index %||% character()))
    )
    cat(paste(values, collapse = ","), "\n", file = metrics_path, append = TRUE)

    cgroup_current <- read_number("/sys/fs/cgroup/memory.current")
    cgroup_max <- read_number("/sys/fs/cgroup/memory.max")
    self_rss <- proc_value_kb("VmRSS")
    if ((!is.na(cgroup_current) && !is.na(cgroup_max) &&
         cgroup_max - cgroup_current < 2 * 1024^3) ||
        (!is.na(self_rss) && self_rss > 2 * 1024^2)) {
      log_event("safety_abort", paste0("rss_kb=", self_rss), paste0("cgroup_current=", cgroup_current))
      writeLines("safety_abort", status_path)
      quit(save = "no", status = 2L)
    }
    next_sample <- elapsed + 5
  }
  Sys.sleep(0.1)
}

writeLines("completed", status_path)
log_event("soak_completed", paste0("elapsed_s=", sprintf("%.3f", as.numeric(difftime(Sys.time(), start_time, units = "secs")))))
