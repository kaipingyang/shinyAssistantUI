# Canonical local diagnostics backend (schema v1). No content, path, raw ID,
# PID, error text, stack, or network transport is accepted by this module.

.diagnostics_schema_path <- function() {
  installed <- system.file("schema", "diagnostics-v1.json", package = "shinyAssistantUI")
  source <- file.path("inst", "schema", "diagnostics-v1.json")
  if (file.exists(source)) normalizePath(source, winslash = "/") else installed
}

.diagnostics_schema_cache <- new.env(parent = emptyenv())
.diagnostics_schema <- function(path = NULL) {
  cached <- .diagnostics_schema_cache$value
  cached_path <- .diagnostics_schema_cache$path
  if (is.null(path) && !is.null(cached)) return(cached)
  if (is.null(path)) path <- .diagnostics_schema_path()
  if (!is.null(cached) && identical(cached_path, path)) return(cached)
  parsed <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.list(parsed) || !identical(parsed$artifactVersion, 1L) ||
      !is.list(parsed$events) || !length(parsed$events)) return(NULL)
  .diagnostics_schema_cache$value <- parsed
  .diagnostics_schema_cache$path <- path
  parsed
}

# Compatibility metadata used only to aggregate Claude SDK classes before rows
# reach the canonical schema. None of these strings are serialized directly.
.diagnostics_enum_metrics <- list(
  message_class = c(
    "StreamEvent", "UserMessage", "AssistantMessage", "ResultMessage",
    "SystemMessage", "PermissionRequestMessage", "TaskStartedMessage",
    "TaskProgressMessage", "TaskNotificationMessage", "TaskUpdatedMessage",
    "RateLimitEvent", "HookEventMessage", "UnknownMessage"
  ),
  stream_type = c(
    "content_block_start", "content_block_delta", "content_block_stop",
    "message_start", "message_delta", "message_stop", "unknown"
  ),
  reason_category = c(
    "invalid_config", "invalid_event", "invalid_metric", "oversize",
    "queue_full", "serialize", "write", "rotation", "payload",
    "permission", "random", "name_collision", "dependency", "closed", "unsupported"
  )
)
.diagnostics_numeric_metrics <- c("count", "bytes")
.diagnostics_logical_metrics <- character()

.diagnostics_default_dir <- function() .claude_addin_path("diagnostics")
.diagnostics_disabled_config <- function(reason = NULL) list(enabled = FALSE, sampled = FALSE, reason = reason)

.cancel_later_timer <- function(timer) {
  if (is.null(timer)) return(invisible(FALSE))
  if (!is.function(timer)) stop("Expected a later cancellation function", call. = FALSE)
  invisible(timer())
}
.diagnostics_scalar_logical <- function(value) is.logical(value) && length(value) == 1L && !is.na(value)
.diagnostics_scalar_character <- function(value) is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value)
.diagnostics_integer_in <- function(value, lower, upper) {
  is.numeric(value) && length(value) == 1L && !is.na(value) && is.finite(value) &&
    value == floor(value) && value >= lower && value <= upper
}
.diagnostics_safe_integer <- function(value) {
  if (!.diagnostics_integer_in(value, 0, 2^53 - 1)) NULL else as.numeric(value)
}

.diagnostics_unique_callbacks <- function(callbacks) {
  sinks <- list()
  Filter(function(callback) {
    if (!is.function(callback)) return(FALSE)
    sink <- attr(callback, "diagnostics_sink", exact = TRUE)
    if (!is.function(sink)) return(TRUE)
    if (any(vapply(sinks, identical, logical(1), y = sink))) return(FALSE)
    sinks[[length(sinks) + 1L]] <<- sink
    TRUE
  }, callbacks)
}

.normalize_diagnostics_config <- function(config = NULL,
                                          sample_uniform = function() stats::runif(1)) {
  if (is.null(config) || identical(config, FALSE)) return(.diagnostics_disabled_config())
  if (identical(config, TRUE)) config <- list(enabled = TRUE)
  if (!is.list(config) || !.diagnostics_scalar_logical(config$enabled) || !isTRUE(config$enabled))
    return(.diagnostics_disabled_config(if (is.list(config) && identical(config$enabled, FALSE)) NULL else "invalid_config"))
  schema <- .diagnostics_schema()
  if (is.null(schema)) return(.diagnostics_disabled_config("dependency"))
  defaults <- list(
    enabled = TRUE, directory = .diagnostics_default_dir(), sample_rate = 1,
    frontend_batch_ms = 1000L, frontend_batch_max = 100L,
    frontend_queue_max = 1000L, frontend_batch_max_bytes = 65536L,
    event_max_bytes = as.integer(schema$limits$rowBytes),
    buffer_max_events = 100L, flush_interval_ms = 0L,
    max_file_bytes = as.integer(schema$limits$fileBytes),
    retention_max_bytes = as.numeric(schema$limits$retentionBytes),
    retention_seconds = as.numeric(schema$limits$retentionSeconds),
    max_files = 20L
  )
  for (name in intersect(names(config), names(defaults))) defaults[[name]] <- config[[name]]
  valid <- .diagnostics_scalar_character(defaults$directory) &&
    is.numeric(defaults$sample_rate) && length(defaults$sample_rate) == 1L &&
    is.finite(defaults$sample_rate) && defaults$sample_rate > 0 && defaults$sample_rate <= 1 &&
    .diagnostics_integer_in(defaults$frontend_batch_ms, 0, 60000) &&
    .diagnostics_integer_in(defaults$frontend_batch_max, 1, schema$limits$batchRows) &&
    .diagnostics_integer_in(defaults$frontend_queue_max, 1, schema$limits$queueRows) &&
    defaults$frontend_batch_max <= defaults$frontend_queue_max &&
    .diagnostics_integer_in(defaults$frontend_batch_max_bytes, 4096, 262144) &&
    .diagnostics_integer_in(defaults$event_max_bytes, 512, schema$limits$rowBytes) &&
    .diagnostics_integer_in(defaults$buffer_max_events, 1, schema$limits$queueRows) &&
    .diagnostics_integer_in(defaults$max_file_bytes, 4096, schema$limits$fileBytes) &&
    .diagnostics_integer_in(defaults$retention_max_bytes, 1024, schema$limits$retentionBytes) &&
    .diagnostics_integer_in(defaults$retention_seconds, 1, schema$limits$retentionSeconds)
  if (!valid) return(.diagnostics_disabled_config("invalid_config"))
  draw <- tryCatch(sample_uniform(), error = function(e) NA_real_)
  if (!is.numeric(draw) || length(draw) != 1L || !is.finite(draw) || draw < 0 || draw >= 1)
    return(.diagnostics_disabled_config("invalid_config"))
  if (draw >= defaults$sample_rate) return(.diagnostics_disabled_config("not_sampled"))
  integer_fields <- c("frontend_batch_ms", "frontend_batch_max", "frontend_queue_max",
                      "frontend_batch_max_bytes", "event_max_bytes", "buffer_max_events",
                      "flush_interval_ms", "max_file_bytes", "max_files")
  for (field in integer_fields) defaults[[field]] <- as.integer(defaults[[field]])
  defaults$sampled <- TRUE
  defaults
}

.diagnostics_launch_from_env <- function(enabled_value = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS", unset = ""),
                                         directory_value = Sys.getenv("SHINYASSISTANTUI_DIAGNOSTICS_DIR", unset = "")) {
  value <- tolower(trimws(as.character(enabled_value %||% "")[[1L]]))
  if (!nzchar(value)) return(NULL)
  if (!value %in% c("1", "true", "yes", "on")) return(FALSE)
  directory <- trimws(as.character(directory_value %||% "")[[1L]])
  if (nzchar(directory)) list(enabled = TRUE, directory = directory) else list(enabled = TRUE)
}

.diagnostics_os_random <- function(n) {
  con <- file("/dev/urandom", "rb", raw = TRUE); on.exit(close(con), add = TRUE)
  readBin(con, "raw", n = n)
}
.diagnostics_hex_token <- function(bytes = .diagnostics_os_random, n = 16L) {
  value <- tryCatch(bytes(n), error = function(e) raw())
  if (!is.raw(value) || length(value) != n) return(NULL)
  paste0(format(value), collapse = "")
}
.new_diagnostics_context <- function(token_bytes = .diagnostics_os_random) {
  token <- .diagnostics_hex_token(token_bytes)
  if (is.null(token)) stop(structure(list(message = "Diagnostics unavailable", call = NULL),
                                     class = c("shinyAssistantUI_diagnostics_disabled", "error", "condition")))
  list(generation = token, session = token,
       token_for = function(...) NULL,
       new_token = function(prefix) paste0(prefix, "_", .diagnostics_hex_token(token_bytes)),
       snapshot = function() list())
}

.diagnostics_metric_valid <- function(value, rule) {
  type <- as.character(rule$type %||% "")[[1L]]
  if (identical(type, "safe-int")) return(!is.null(.diagnostics_safe_integer(value)))
  if (identical(type, "enum")) return(.diagnostics_scalar_character(value) &&
    value %in% unlist(rule$values, use.names = FALSE))
  FALSE
}

.diagnostics_canonical_row <- function(event, metrics = list(), now = Sys.time) {
  schema <- .diagnostics_schema()
  if (is.null(schema) || !.diagnostics_scalar_character(event) ||
      !event %in% names(schema$events) || !is.list(metrics) ||
      (length(metrics) && is.null(names(metrics)))) return(NULL)
  rules <- schema$events[[event]]
  expected <- names(rules) %||% character()
  actual <- names(metrics) %||% character()
  if (!identical(actual, expected)) return(NULL)
  output <- list()
  for (name in expected) {
    if (!.diagnostics_metric_valid(metrics[[name]], rules[[name]])) return(NULL)
    output[[name]] <- if (identical(rules[[name]]$type, "safe-int"))
      .diagnostics_safe_integer(metrics[[name]]) else as.character(metrics[[name]])[[1L]]
  }
  timestamp <- tryCatch(now(), error = function(e) NA_real_)
  if (inherits(timestamp, "POSIXt")) timestamp <- floor(as.numeric(timestamp))
  timestamp <- .diagnostics_safe_integer(timestamp)
  if (is.null(timestamp)) return(NULL)
  list(schema = 1L, event = event, ts = timestamp, metrics = output)
}

.diagnostics_canonical_encode <- function(row, validate = TRUE) {
  if (!is.list(row) || !identical(names(row), c("schema", "event", "ts", "metrics"))) return(NULL)
  if (isTRUE(validate)) {
    validated <- .diagnostics_canonical_row(row$event, row$metrics, now = function() row$ts)
    if (is.null(validated) || !identical(validated, row)) return(NULL)
  }
  encode_integer <- function(value) format(value, scientific = FALSE, trim = TRUE,
                                           digits = 22, nsmall = 0)
  metric_names <- names(row$metrics) %||% character()
  metric_values <- vapply(metric_names, function(name) {
    value <- row$metrics[[name]]
    encoded <- if (is.character(value)) paste0('"', value, '"') else encode_integer(value)
    paste0('"', name, '":', encoded)
  }, character(1))
  paste0(
    '{"schema":1,"event":"', row$event, '","ts":', encode_integer(row$ts),
    ',"metrics":{', paste(metric_values, collapse = ","), '}}\n'
  )
}

.diagnostics_memory_state <- function(value) {
  if (value %in% c("hard_pending", "hard_idle", "hard")) return("hard")
  if (value %in% c("normal", "soft", "unknown", "unsupported")) return(value)
  "unknown"
}
.diagnostics_nonnegative <- function(value, fallback = 0) {
  out <- .diagnostics_safe_integer(value)
  if (is.null(out)) as.numeric(fallback) else out
}

# Map existing backend callback vocabulary onto the canonical aggregate schema.
# Unknown metadata-only signals are intentionally dropped.
.diagnostics_normalize_event <- function(source, event, metrics) {
  metrics <- if (is.list(metrics)) metrics else list()
  if (event %in% names(.diagnostics_schema()$events)) return(list(event = event, metrics = metrics))
  switch(event,
    diagnostics_start = list(event = "storage_outcome", metrics = list(
      operation = "startup", outcome = "ok", count = 1, bytes = 0)),
    cleanup_start = NULL,
    cleanup_end = list(event = "storage_outcome", metrics = list(
      operation = "close", outcome = "ok", count = 1, bytes = 0)),
    turn_admitted = list(event = "run_state", metrics = list(phase = "queued")),
    turn_done = list(event = "run_state", metrics = list(phase = "complete")),
    turn_error = list(event = "run_state", metrics = list(phase = "error")),
    turn_cancelled = list(event = "run_state", metrics = list(phase = "cancelled")),
    result = list(event = "run_state", metrics = list(phase = if (isTRUE(metrics$success)) "complete" else "error")),
    poll_batch = list(event = "chunk_summary", metrics = list(
      count = .diagnostics_nonnegative(metrics$batch_count %||% metrics$count),
      bytes = .diagnostics_nonnegative(metrics$bytes))),
    tool_delta_summary = list(event = "tool_delta_summary", metrics = list(
      count = .diagnostics_nonnegative(metrics$count),
      bytes = .diagnostics_nonnegative(metrics$bytes),
      toolCount = .diagnostics_nonnegative(metrics$toolCount %||% metrics$tool_count))),
    memory_sample = list(event = "memory_guard_sample", metrics = list(
      state = .diagnostics_memory_state(metrics$guard_state %||% "unknown"),
      pssBytes = .diagnostics_nonnegative(metrics$pss_bytes),
      rssBytes = .diagnostics_nonnegative(metrics$rss_bytes),
      privateDirtyBytes = .diagnostics_nonnegative(metrics$private_dirty_bytes),
      anonymousBytes = .diagnostics_nonnegative(metrics$anonymous_bytes),
      cgroupCurrentBytes = .diagnostics_nonnegative(metrics$cgroup_current_bytes),
      cgroupMaxBytes = .diagnostics_nonnegative(metrics$cgroup_max_bytes),
      cgroupLimit = if (identical(metrics$cgroup_limit, "limited")) "limited" else
        if (identical(metrics$cgroup_limit, "unlimited")) "unlimited" else "unknown",
      cgroupHighEvents = .diagnostics_nonnegative(metrics$cgroup_high_events),
      cgroupMaxEvents = .diagnostics_nonnegative(metrics$cgroup_max_events),
      cgroupOomEvents = .diagnostics_nonnegative(metrics$cgroup_oom_events),
      cgroupOomKillEvents = .diagnostics_nonnegative(metrics$cgroup_oom_kill_events),
      rHeapAfterGcBytes = .diagnostics_nonnegative(metrics$r_heap_after_gc_bytes),
      guardGcCount = .diagnostics_nonnegative(metrics$guard_gc_count),
      sdkClientCount = .diagnostics_nonnegative(metrics$sdk_client_count),
      sdkConsumerCount = .diagnostics_nonnegative(metrics$sdk_consumer_count),
      sdkRouteCount = .diagnostics_nonnegative(metrics$sdk_route_count),
      sdkMessagesSeen = .diagnostics_nonnegative(metrics$sdk_messages_seen),
      sdkMessageBytesSeen = .diagnostics_nonnegative(metrics$sdk_message_bytes_seen),
      sdkMaxBatchBytes = .diagnostics_nonnegative(metrics$sdk_max_batch_bytes),
      sdkBufferedMessageCount = .diagnostics_nonnegative(metrics$sdk_buffered_message_count),
      sdkWaiterCount = .diagnostics_nonnegative(metrics$sdk_waiter_count),
      sdkUsageProbePendingCount = .diagnostics_nonnegative(metrics$sdk_usage_probe_pending_count),
      activeTurnCount = .diagnostics_nonnegative(metrics$active_turn_count),
      softPssBytes = .diagnostics_nonnegative(metrics$soft_pss_bytes),
      hardPssBytes = .diagnostics_nonnegative(metrics$hard_pss_bytes),
      softRssBytes = .diagnostics_nonnegative(metrics$soft_rss_bytes),
      hardRssBytes = .diagnostics_nonnegative(metrics$hard_rss_bytes))),
    js_heap_sample = list(event = "page_js_heap_sample", metrics = list(
      pageJsHeapBytes = .diagnostics_nonnegative(metrics$heap_used_bytes))),
    ui_counts = list(event = "ui_counts", metrics = list(
      messageCount = .diagnostics_nonnegative(metrics$messageCount %||% metrics$message_count),
      toolCardCount = .diagnostics_nonnegative(metrics$toolCardCount %||% metrics$tool_card_count),
      domCardCount = .diagnostics_nonnegative(metrics$domCardCount %||% metrics$dom_card_count))),
    longtask_summary = list(event = "longtask_summary", metrics = list(
      count = .diagnostics_nonnegative(metrics$count),
      durationUs = .diagnostics_nonnegative((metrics$duration_ms %||% 0) * 1000),
      maxUs = .diagnostics_nonnegative((metrics$max_ms %||% 0) * 1000))),
    NULL
  )
}

.diagnostics_safe_event <- function(source, event, metrics = list(), context = NULL,
                                    thread_id = NULL, run_id = NULL,
                                    now = Sys.time, pid = Sys.getpid()) {
  if (!.diagnostics_scalar_character(source) || !source %in% c("backend", "frontend")) return(NULL)
  normalized <- .diagnostics_normalize_event(source, event, metrics)
  if (is.null(normalized)) return(NULL)
  .diagnostics_canonical_row(normalized$event, normalized$metrics, now)
}
.diagnostics_safe_metrics <- function(metrics) if (is.list(metrics)) metrics else list()
.diagnostics_saturating_add <- function(value, increment = 1) min(2^53 - 1, max(0, value %||% 0) + max(0, increment %||% 0))

.diagnostics_default_schedule <- function(callback, delay = 0) {
  if (!requireNamespace("later", quietly = TRUE)) return(NULL)
  timer <- later::later(callback, delay = delay)
  function() .cancel_later_timer(timer)
}

.diagnostics_process_alive <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid < 1L) return(NA)
  if (.Platform$OS.type != "unix" || !dir.exists("/proc")) return(NA)
  dir.exists(file.path("/proc", pid))
}
.diagnostics_regular_safe <- function(path) {
  info <- tryCatch(file.info(path), error = function(e) NULL)
  !is.null(info) && nrow(info) == 1L && !isTRUE(info$isdir[[1L]]) &&
    identical(Sys.readlink(path), "")
}
.diagnostics_retention_lock <- function(root) {
  path <- file.path(root, ".retention.lock")
  if (!dir.create(path, mode = "0700", showWarnings = FALSE)) return(NULL)
  token <- .diagnostics_hex_token() %||% paste0(Sys.getpid(), "-fallback")
  writeLines(token, file.path(path, "token")); list(path = path, token = token)
}
.diagnostics_retention_unlock <- function(lock) {
  if (!is.list(lock) || !dir.exists(lock$path)) return(invisible(FALSE))
  token <- tryCatch(readLines(file.path(lock$path, "token"), n = 1L), error = function(e) "")
  if (identical(token, lock$token)) unlink(lock$path, recursive = TRUE, force = TRUE)
  invisible(TRUE)
}

.diagnostics_retention_pass <- function(root, now = Sys.time(), max_bytes = 50 * 1024^2,
                                        max_age = 7 * 24 * 60 * 60) {
  result <- list(category = "ok", deleted_count = 0, deleted_bytes = 0,
                 retained_bytes = 0, protected_count = 0)
  if (!dir.exists(root)) return(result)
  lock <- .diagnostics_retention_lock(root)
  if (is.null(lock)) { result$category <- "busy"; return(result) }
  on.exit(.diagnostics_retention_unlock(lock), add = TRUE)
  now_value <- if (is.function(now)) now() else now
  now_seconds <- as.numeric(now_value)
  entries <- list.files(root, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  new_re <- "^diag-v1-([0-9]{13})-([0-9a-f]{32})\\.jsonl$"
  legacy_re <- "^diagnostics-g_[A-Za-z0-9][A-Za-z0-9_-]{0,63}-s_[A-Za-z0-9][A-Za-z0-9_-]{0,63}-p([1-9][0-9]{0,9})-u_[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.jsonl(?:\\.[1-9][0-9]{0,5})?$"
  candidates <- list()
  for (path in entries) {
    base <- basename(path)
    if (!.diagnostics_regular_safe(path)) next
    info <- file.info(path)
    kind <- if (grepl(new_re, base)) "new" else if (grepl(legacy_re, base)) "legacy" else NULL
    if (is.null(kind)) next
    active <- FALSE
    created <- as.numeric(info$mtime)
    if (kind == "new") {
      created <- as.numeric(sub(new_re, "\\1", base)) / 1000
      lease <- paste0(path, ".lease")
      if (file.exists(lease)) {
        owner <- tryCatch(jsonlite::fromJSON(lease, simplifyVector = FALSE), error = function(e) NULL)
        if (is.list(owner) && !is.null(owner$pid)) {
          current_start <- .settings_process_start_token(owner$pid)
          if (is.null(current_start)) {
            active <- !(.Platform$OS.type == "unix" && dir.exists("/proc"))
          } else if (.diagnostics_scalar_character(owner$startToken) &&
                     !identical(owner$startToken, "unsupported")) {
            active <- identical(current_start, owner$startToken)
          } else {
            active <- TRUE
          }
        } else {
          active <- TRUE
        }
      }
    } else {
      pid <- suppressWarnings(as.integer(sub(legacy_re, "\\1", base)))
      first <- .diagnostics_process_alive(pid); second <- .diagnostics_process_alive(pid)
      active <- !identical(first, FALSE) || !identical(second, FALSE)
    }
    candidates[[length(candidates) + 1L]] <- list(
      path = path, size = as.numeric(info$size), created = created,
      active = active, basename = base
    )
  }
  remove_candidate <- function(candidate) {
    before <- tryCatch(file.info(candidate$path), error = function(e) NULL)
    if (is.null(before) || isTRUE(candidate$active) || !.diagnostics_regular_safe(candidate$path)) return(FALSE)
    if (unlink(candidate$path, force = TRUE) == 0L && !file.exists(candidate$path)) {
      result$deleted_count <<- result$deleted_count + 1
      result$deleted_bytes <<- result$deleted_bytes + candidate$size
      TRUE
    } else FALSE
  }
  for (candidate in candidates) {
    if (!candidate$active && is.finite(candidate$created) && now_seconds - candidate$created > max_age)
      remove_candidate(candidate)
  }
  remaining <- Filter(function(x) file.exists(x$path), candidates)
  total <- sum(vapply(remaining, `[[`, numeric(1), "size"))
  inactive <- Filter(function(x) !x$active, remaining)
  inactive <- inactive[order(vapply(inactive, `[[`, numeric(1), "created"),
                             vapply(inactive, `[[`, character(1), "basename"))]
  for (candidate in inactive) {
    if (total <= max_bytes) break
    if (remove_candidate(candidate)) total <- total - candidate$size
  }
  remaining <- Filter(function(x) file.exists(x$path), candidates)
  result$retained_bytes <- sum(vapply(remaining, `[[`, numeric(1), "size"))
  result$protected_count <- sum(vapply(remaining, `[[`, logical(1), "active"))
  if (result$retained_bytes > max_bytes) result$category <- "partial"
  result
}

.new_diagnostics_writer <- function(config, context = NULL,
                                    schedule = .diagnostics_default_schedule,
                                    warn = function(category) warning(paste0("Diagnostics disabled: ", category), call. = FALSE),
                                    now = Sys.time, pid = Sys.getpid(),
                                    dependency_available = function() requireNamespace("jsonlite", quietly = TRUE),
                                    chmod_file = Sys.chmod,
                                    elapsed = function() proc.time()[["elapsed"]]) {
  normalized <- if (is.list(config) && isTRUE(config$sampled)) config else
    .normalize_diagnostics_config(config, sample_uniform = function() 0)
  state <- new.env(parent = emptyenv())
  state$enabled <- isTRUE(normalized$enabled); state$closed <- FALSE
  state$queue <- list(); state$timer_cancel <- NULL; state$storage <- NULL
  state$path <- NULL; state$lease <- NULL; state$active_bytes <- 0
  state$written_events <- 0; state$dropped_events <- 0; state$rotation_count <- 0
  state$retention <- NULL; state$warned <- FALSE; state$rotate_requested <- FALSE
  warn_once <- function(category) if (!state$warned) {
    state$warned <- TRUE; tryCatch(warn(category), error = function(e) NULL)
  }
  disable <- function(category) {
    state$enabled <- FALSE; warn_once(category); invisible(FALSE)
  }
  close_file <- function(remove_lease = TRUE) {
    if (!is.null(state$storage)) tryCatch(state$storage$close(), error = function(e) NULL)
    state$storage <- NULL; state$lease <- NULL
  }
  open_file <- function() {
    if (!state$enabled || state$closed) return(FALSE)
    if (!isTRUE(tryCatch(dependency_available(), error = function(e) FALSE)))
      return(disable("dependency"))
    storage <- tryCatch(.new_diagnostics_storage(normalized, now = now),
                        error = function(error) NULL)
    snapshot <- if (is.null(storage)) NULL else tryCatch(
      storage$snapshot(), error = function(error) NULL
    )
    if (is.null(snapshot) || !isTRUE(snapshot$active))
      return(disable(snapshot$category %||% "io_error"))
    state$storage <- storage
    state$path <- file.path(normalized$directory, snapshot$basename)
    state$lease <- file.path(normalized$directory, snapshot$lease_basename)
    state$active_bytes <- snapshot$bytes
    state$retention <- snapshot$retention
    TRUE
  }
  rotate <- function() {
    if (is.null(state$storage) || !isTRUE(state$storage$rotate())) return(FALSE)
    snapshot <- state$storage$snapshot()
    state$path <- file.path(normalized$directory, snapshot$basename)
    state$lease <- file.path(normalized$directory, snapshot$lease_basename)
    state$active_bytes <- snapshot$bytes
    state$retention <- snapshot$retention
    state$rotation_count <- .diagnostics_saturating_add(state$rotation_count)
    TRUE
  }
  flush <- function() {
    state$timer_cancel <- NULL
    if (!state$enabled || state$closed) return(invisible(FALSE))
    rows <- state$queue; state$queue <- list()
    if (!length(rows)) return(invisible(TRUE))
    if (is.null(state$storage) && !open_file()) return(invisible(FALSE))
    started <- elapsed()
    native_lines <- .native_encode_validated_rows(rows)
    encoded <- if (!is.null(native_lines)) {
      lapply(native_lines, function(line) list(
        line = line, bytes = nchar(line, type = "bytes")
      ))
    } else lapply(rows, function(row) {
      line <- tryCatch(.diagnostics_canonical_encode(row, validate = FALSE), error = function(e) NULL)
      bytes <- if (is.null(line)) Inf else nchar(line, type = "bytes")
      if (is.null(line) || bytes > normalized$event_max_bytes) {
        state$dropped_events <- .diagnostics_saturating_add(state$dropped_events)
        return(NULL)
      }
      list(line = line, bytes = bytes)
    })
    encoded <- Filter(Negate(is.null), encoded)
    write_chunk <- function(chunk, bytes) {
      if (!length(chunk)) return(TRUE)
      payload <- charToRaw(paste0(chunk, collapse = ""))
      ok <- tryCatch(state$storage$write(payload), error = function(e) FALSE)
      if (!ok) return(FALSE)
      state$active_bytes <- state$active_bytes + bytes
      state$written_events <- .diagnostics_saturating_add(state$written_events, length(chunk))
      TRUE
    }
    chunk <- character(length(encoded)); chunk_count <- 0L; chunk_bytes <- 0
    for (index in seq_along(encoded)) {
      item <- encoded[[index]]
      if (state$active_bytes + chunk_bytes + item$bytes > normalized$max_file_bytes) {
        if (!write_chunk(chunk[seq_len(chunk_count)], chunk_bytes)) return(disable("write"))
        chunk_count <- 0L; chunk_bytes <- 0
        if (!rotate()) return(invisible(FALSE))
      }
      chunk_count <- chunk_count + 1L; chunk[[chunk_count]] <- item$line
      chunk_bytes <- chunk_bytes + item$bytes
      if ((elapsed() - started) * 1000 > 25) {
        state$dropped_events <- .diagnostics_saturating_add(
          state$dropped_events, length(encoded) - index + chunk_count
        )
        return(disable("write"))
      }
    }
    if (chunk_count && !write_chunk(chunk[seq_len(chunk_count)], chunk_bytes))
      return(disable("write"))
    if (isTRUE(state$rotate_requested)) {
      state$rotate_requested <- FALSE
      if (!rotate()) return(invisible(FALSE))
    }
    invisible(TRUE)
  }
  arm <- function() {
    if (!state$enabled || state$closed || !length(state$queue) || !is.null(state$timer_cancel) || !is.function(schedule)) return(invisible(NULL))
    state$timer_cancel <- tryCatch(schedule(flush, 0), error = function(e) NULL)
    invisible(NULL)
  }
  enqueue <- function(source, event, metrics = list(), thread_id = NULL, run_id = NULL, flush_now = FALSE) {
    if (!state$enabled || state$closed) return(FALSE)
    row <- .diagnostics_safe_event(source, event, metrics, context, thread_id, run_id, now, pid)
    if (is.null(row)) { state$dropped_events <- .diagnostics_saturating_add(state$dropped_events); return(FALSE) }
    if (length(state$queue) >= normalized$buffer_max_events) {
      state$dropped_events <- .diagnostics_saturating_add(state$dropped_events); return(FALSE)
    }
    state$queue[[length(state$queue) + 1L]] <- row
    arm(); TRUE
  }
  ingest <- function(batch) {
    if (!state$enabled || state$closed || !is.list(batch) ||
        !identical(names(batch), c("version", "schema", "rows")) ||
        !identical(batch$version, 2L) || !identical(batch$schema, 1L) ||
        !is.list(batch$rows) || length(batch$rows) > normalized$frontend_batch_max) return(FALSE)
    accepted <- TRUE
    for (row in batch$rows) {
      exact <- is.list(row) && identical(names(row), c("schema", "event", "ts", "metrics")) &&
        identical(row$schema, 1L)
      canonical <- if (exact) {
        .diagnostics_canonical_row(row$event, row$metrics, now = function() row$ts)
      } else NULL
      if (is.null(canonical) ||
          length(state$queue) >= normalized$buffer_max_events) {
        state$dropped_events <- .diagnostics_saturating_add(state$dropped_events)
        accepted <- FALSE
      } else {
        state$queue[[length(state$queue) + 1L]] <- canonical
        arm()
      }
    }
    accepted
  }
  stop_timer <- function() {
    cancel <- state$timer_cancel; state$timer_cancel <- NULL
    if (is.function(cancel)) tryCatch(cancel(), error = function(e) NULL)
    invisible(TRUE)
  }
  close_writer <- function() {
    if (state$closed) return(TRUE)
    stop_timer(); flush()
    if (!is.null(state$storage)) {
      state$storage$close()
      state$retention <- state$storage$snapshot()$retention
      state$storage <- NULL
    }
    state$closed <- TRUE; state$enabled <- FALSE
    TRUE
  }
  snapshot <- function() list(
    enabled = state$enabled, closed = state$closed, path = state$path,
    buffered_events = length(state$queue), written_events = state$written_events,
    dropped_events = state$dropped_events, pending_drops = 0,
    rotation_count = state$rotation_count, active_bytes = state$active_bytes,
    retention = state$retention
  )
  request_rotation <- function() {
    if (!state$enabled || state$closed) return(FALSE)
    state$rotate_requested <- TRUE
    TRUE
  }
  list(write_event = enqueue, ingest_frontend_batch = ingest, flush = flush,
       request_rotation = request_rotation, stop_timer = stop_timer,
       snapshot = snapshot, close = close_writer)
}

.diagnostics_nearest_rank <- function(values, probability) {
  if (!is.numeric(values) || !length(values) || any(!is.finite(values)) ||
      !is.numeric(probability) || length(probability) != 1L ||
      !is.finite(probability) || probability <= 0 || probability > 1) {
    return(NA_real_)
  }
  ordered <- sort(as.numeric(values), method = "radix")
  ordered[[ceiling(probability * length(ordered))]]
}

.diagnostics_benchmark_event <- function(index) {
  slot <- ((as.integer(index) - 1L) %% 100L) + 1L
  cycle <- ((as.integer(index) - 1L) %/% 100L) + 1L
  boundary <- c(0, 1, 42, 65535, 2^31 - 1, 2^53 - 1)
  value <- boundary[[(cycle - 1L) %% length(boundary) + 1L]]
  if (slot <= 35L) return(list(event = "chunk_summary", metrics = list(
    count = value, bytes = boundary[[slot %% length(boundary) + 1L]]
  )))
  if (slot <= 55L) return(list(event = "tool_delta_summary", metrics = list(
    count = value, bytes = boundary[[slot %% length(boundary) + 1L]],
    toolCount = boundary[[(slot + 1L) %% length(boundary) + 1L]]
  )))
  if (slot <= 70L) return(list(event = "owned_markdown_preprocess_summary", metrics = list(
    count = value, durationUs = boundary[[slot %% length(boundary) + 1L]],
    maxUs = boundary[[(slot + 1L) %% length(boundary) + 1L]]
  )))
  if (slot <= 80L) return(list(event = "frame_summary", metrics = list(
    count = value, p95IntervalUs = boundary[[slot %% length(boundary) + 1L]],
    maxIntervalUs = boundary[[(slot + 1L) %% length(boundary) + 1L]],
    jankCount = boundary[[(slot + 2L) %% length(boundary) + 1L]]
  )))
  if (slot <= 90L) return(list(event = "memory_guard_sample", metrics = list(
    state = c("normal", "soft", "hard", "unknown", "unsupported")[[cycle %% 5L + 1L]],
    pssBytes = value, rssBytes = value,
    privateDirtyBytes = value, anonymousBytes = value,
    cgroupCurrentBytes = value, cgroupMaxBytes = value,
    cgroupLimit = c("limited", "unlimited", "unknown")[[cycle %% 3L + 1L]],
    cgroupHighEvents = value, cgroupMaxEvents = value,
    cgroupOomEvents = value, cgroupOomKillEvents = value,
    rHeapAfterGcBytes = value, guardGcCount = value,
    sdkClientCount = value, sdkConsumerCount = value, sdkRouteCount = value,
    sdkMessagesSeen = value, sdkMessageBytesSeen = value,
    sdkMaxBatchBytes = value, sdkBufferedMessageCount = value,
    sdkWaiterCount = value, sdkUsageProbePendingCount = value,
    activeTurnCount = value,
    softPssBytes = value,
    hardPssBytes = value, softRssBytes = value, hardRssBytes = value
  )))
  if (slot <= 95L) return(list(event = "storage_outcome", metrics = list(
    operation = c("startup", "rotation", "close", "retention", "clear", "export")[[cycle %% 6L + 1L]],
    outcome = c("ok", "busy", "unsupported", "io_error", "invalid", "partial")[[cycle %% 6L + 1L]],
    count = value, bytes = value
  )))
  list(event = "telemetry_batch_drop", metrics = list(
    count = value,
    reason = c("invalid_config", "invalid_event", "invalid_metric", "oversize",
               "queue_full", "serialize", "write", "rotation", "payload",
               "permission", "random", "name_collision", "dependency", "closed",
               "unsupported")[[cycle %% 15L + 1L]]
  ))
}

.benchmark_diagnostics_writer <- function(
    directory = tempfile("plan123-writer-benchmark-"),
    writer_factory = .new_diagnostics_writer,
    warmup_enqueues = 1000L, warmup_flushes = 20L,
    measured_enqueues = 10000L, measured_flushes = 200L,
    rotation_batches = c(40L, 80L, 120L, 160L), seed = 123L,
    inter_batch_delay = 0.005) {
  protocol_ok <- identical(as.integer(warmup_enqueues), 1000L) &&
    identical(as.integer(warmup_flushes), 20L) &&
    identical(as.integer(measured_enqueues), 10000L) &&
    identical(as.integer(measured_flushes), 200L) &&
    identical(as.integer(rotation_batches), c(40L, 80L, 120L, 160L)) &&
    identical(as.integer(seed), 123L) &&
    is.numeric(inter_batch_delay) && length(inter_batch_delay) == 1L &&
    identical(as.numeric(inter_batch_delay), 0.005)
  if (!protocol_ok || warmup_enqueues %% warmup_flushes != 0L ||
      measured_enqueues %% measured_flushes != 0L) {
    stop("The Plan 123 writer benchmark protocol is immutable", call. = FALSE)
  }
  rows_per_flush <- as.integer(measured_enqueues / measured_flushes)
  if (!dir.exists(directory) &&
      !dir.create(directory, recursive = TRUE, mode = "0700", showWarnings = FALSE)) {
    stop("Unable to create HOME benchmark directory", call. = FALSE)
  }
  set.seed(seed)
  config <- .normalize_diagnostics_config(list(
    enabled = TRUE, directory = directory, buffer_max_events = 1000L,
    max_file_bytes = 10485760L, retention_max_bytes = 52428800,
    retention_seconds = 604800
  ), sample_uniform = function() 0)
  writer <- writer_factory(config, schedule = NULL)
  on.exit(writer$close(), add = TRUE)
  write_one <- function(index) {
    payload <- .diagnostics_benchmark_event(index)
    isTRUE(writer$write_event("backend", payload$event, payload$metrics))
  }
  warmup_rows <- as.integer(warmup_enqueues / warmup_flushes)
  for (batch in seq_len(warmup_flushes)) {
    first <- (batch - 1L) * warmup_rows + 1L
    if (!all(vapply(first:(first + warmup_rows - 1L), write_one, logical(1))))
      stop("Warmup enqueue failed", call. = FALSE)
    if (!isTRUE(writer$flush())) stop("Warmup flush failed", call. = FALSE)
    Sys.sleep(inter_batch_delay)
  }
  enqueue_ms <- numeric(measured_enqueues)
  flush_ms <- numeric(measured_flushes)
  event_names <- character(measured_enqueues)
  observed <- integer()
  measured_index <- 0L
  for (batch in seq_len(measured_flushes)) {
    for (row in seq_len(rows_per_flush)) {
      measured_index <- measured_index + 1L
      payload <- .diagnostics_benchmark_event(measured_index)
      event_names[[measured_index]] <- payload$event
      started <- .native_monotonic_ns()
      ok <- writer$write_event("backend", payload$event, payload$metrics)
      enqueue_ms[[measured_index]] <- (.native_monotonic_ns() - started) / 1e6
      if (!isTRUE(ok)) stop("Measured enqueue failed", call. = FALSE)
    }
    before <- writer$snapshot()$rotation_count
    if (batch %in% rotation_batches && !writer$request_rotation())
      stop("Rotation request failed", call. = FALSE)
    started <- .native_monotonic_ns()
    ok <- writer$flush()
    flush_ms[[batch]] <- (.native_monotonic_ns() - started) / 1e6
    after <- writer$snapshot()$rotation_count
    if (!isTRUE(ok)) stop("Measured flush failed", call. = FALSE)
    if (after > before) observed <- c(observed, batch)
    Sys.sleep(inter_batch_delay)
  }
  snapshot <- writer$snapshot()
  writer$close()
  files <- list.files(directory,
    pattern = "^diag-v1-[0-9]{13}-[0-9a-f]{32}\\.jsonl$", full.names = TRUE)
  line_count <- sum(lengths(lapply(files, readLines, warn = FALSE)))
  counts <- table(factor(event_names, levels = c(
    "chunk_summary", "tool_delta_summary", "owned_markdown_preprocess_summary",
    "frame_summary", "memory_guard_sample", "storage_outcome",
    "telemetry_batch_drop"
  )))
  event_counts <- as.list(as.integer(counts)); names(event_counts) <- names(counts)
  summary <- list(
    enqueueP95Ms = .diagnostics_nearest_rank(enqueue_ms, 0.95),
    flushP95Ms = .diagnostics_nearest_rank(flush_ms, 0.95),
    flushP99Ms = .diagnostics_nearest_rank(flush_ms, 0.99),
    flushMaxMs = max(flush_ms)
  )
  thresholds <- c(
    enqueueP95 = summary$enqueueP95Ms < 0.2,
    flushP95 = summary$flushP95Ms <= 5,
    flushP99 = summary$flushP99Ms <= 20,
    flushMax = summary$flushMaxMs <= 25
  )
  valid <- isTRUE(as.numeric(line_count) ==
                    as.numeric(warmup_enqueues + measured_enqueues)) &&
    isTRUE(as.numeric(snapshot$written_events) ==
             as.numeric(warmup_enqueues + measured_enqueues)) &&
    identical(observed, as.integer(rotation_batches)) &&
    snapshot$rotation_count >= 4L && length(enqueue_ms) == 10000L &&
    length(flush_ms) == 200L
  list(
    protocol = list(
      warmupEnqueues = warmup_enqueues, warmupFlushes = warmup_flushes,
      measuredEnqueues = measured_enqueues, measuredFlushes = measured_flushes,
      rowsPerFlush = rows_per_flush,
      rotationBatches = as.integer(rotation_batches), seed = as.integer(seed),
      interBatchDelayMs = inter_batch_delay * 1000,
      quantile = "nearest-rank"
    ),
    raw = list(enqueueMs = enqueue_ms, flushMs = flush_ms),
    eventCounts = event_counts, rotationBatchesObserved = observed,
    rotationCount = snapshot$rotation_count, lineCount = line_count,
    summary = summary, thresholds = thresholds,
    valid = isTRUE(valid), passed = isTRUE(valid) && all(thresholds)
  )
}

.start_diagnostics_writer <- function(config, context_factory = .new_diagnostics_context,
                                      writer_factory = .new_isolated_diagnostics_writer,
                                      warn = function(category) warning(paste0("Diagnostics disabled: ", category), call. = FALSE),
                                      schedule = .diagnostics_default_schedule) {
  normalized <- if (is.list(config) && isTRUE(config$sampled)) config else
    .normalize_diagnostics_config(config, sample_uniform = function() 0)
  if (!isTRUE(normalized$enabled)) return(list(state = "off", context = NULL, writer = NULL))
  context <- tryCatch(context_factory(), error = function(e) NULL)
  if (is.null(context)) return(list(state = "failed", context = NULL, writer = NULL))
  writer <- tryCatch(writer_factory(normalized, context, schedule = schedule), error = function(e) NULL)
  if (is.null(writer) || !isTRUE(tryCatch(writer$snapshot()$enabled, error = function(e) FALSE)))
    return(list(state = "failed", context = NULL, writer = NULL))
  list(state = "started", context = context, writer = writer)
}

.new_diagnostics_service <- function(config, schedule = .diagnostics_default_schedule,
                                     writer_factory = .new_isolated_diagnostics_writer) {
  normalized <- .normalize_diagnostics_config(config, sample_uniform = function() 0)
  started <- .start_diagnostics_writer(normalized, writer_factory = writer_factory, schedule = schedule)
  state <- new.env(parent = emptyenv()); state$closed <- FALSE; state$bindings <- 0L
  emit <- function(event, metrics = list()) {
    if (state$closed || !identical(started$state, "started")) return(FALSE)
    isTRUE(tryCatch(started$writer$write_event("backend", event, metrics), error = function(e) FALSE))
  }
  ingest <- function(batch) {
    if (state$closed || !identical(started$state, "started")) return(FALSE)
    isTRUE(tryCatch(started$writer$ingest_frontend_batch(batch), error = function(e) FALSE))
  }
  bind_session <- function() {
    if (state$closed) return(function() FALSE)
    state$bindings <- state$bindings + 1L; done <- FALSE
    function() { if (done) return(FALSE); done <<- TRUE; state$bindings <- max(0L, state$bindings - 1L); TRUE }
  }
  close <- function() {
    if (state$closed) return(FALSE)
    state$closed <- TRUE
    if (!is.null(started$writer)) tryCatch(started$writer$close(), error = function(e) NULL)
    TRUE
  }
  snapshot <- function() c(list(state = started$state, active_bindings = state$bindings,
                                closed = state$closed),
                           if (!is.null(started$writer)) started$writer$snapshot() else list())
  list(emit = emit, ingest_frontend_batch = ingest, bind_session = bind_session,
       close = close, snapshot = snapshot,
       config = function() list(enabled = identical(started$state, "started"), schema = 1L))
}

.benchmark_isolated_diagnostics_writer <- function(directory, ...) {
  .benchmark_diagnostics_writer(
    directory = directory, writer_factory = .new_isolated_diagnostics_writer, ...
  )
}

.diagnostics_export_capability <- function() {
  schema <- .diagnostics_schema()
  list(version = 1L, available = FALSE,
       reason = if (is.null(schema)) "schema_unavailable" else "unsupported",
       schema = 1L, canonical = !is.null(schema), network = FALSE)
}
