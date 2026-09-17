.diagnostics_supervision_cache <- new.env(parent = emptyenv())
.diagnostics_callr_supervisor <- new.env(parent = emptyenv())
.diagnostics_callr_supervisor$records <- list()
.diagnostics_callr_supervisor$references <- 0L

.release_package_callr_supervisor <- function() {
  registry <- .diagnostics_callr_supervisor
  if (registry$references > 0L || !length(registry$records)) return(invisible(FALSE))
  .reap_owned_processes(registry$records)
  registry$records <- list()
  # Audited processx 3.8.x implementation: after the exact owned watchdog has
  # exited, supervisor_reset only clears its cached pid/pipe bookkeeping.
  reset <- tryCatch(get("supervisor_reset", envir = asNamespace("processx")),
                    error = function(error) NULL)
  if (is.function(reset)) tryCatch(reset(), error = function(error) NULL)
  invisible(TRUE)
}

.capture_owned_processes <- function(before = integer()) {
  pids <- setdiff(.owned_descendant_pids(Sys.getpid()), as.integer(before))
  records <- lapply(pids, function(pid) {
    token <- .native_process_start_token(pid)
    if (!.diagnostics_scalar_character(token)) return(NULL)
    list(pid = as.integer(pid), startToken = token)
  })
  Filter(Negate(is.null), records)
}

.reap_owned_processes <- function(records, timeout_ms = 500L) {
  if (!is.list(records)) return(invisible(FALSE))
  outcomes <- vapply(records, function(record) {
    .native_terminate_process(record$pid, record$startToken, timeout_ms)
  }, character(1))
  invisible(all(outcomes %in% c("ok", "changed")))
}

.owned_descendant_pids <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid < 1L || !dir.exists(file.path("/proc", pid))) return(integer())
  seen <- integer(); queue <- pid
  while (length(queue)) {
    current <- queue[[1L]]; queue <- queue[-1L]
    path <- file.path("/proc", current, "task", current, "children")
    text <- tryCatch(readLines(path, n = 1L, warn = FALSE), error = function(error) "")
    trimmed <- if (length(text)) trimws(text[[1L]]) else ""
    children <- if (!nzchar(trimmed)) integer() else
      suppressWarnings(as.integer(strsplit(trimmed, "[[:space:]]+")[[1L]]))
    children <- children[!is.na(children) & children > 0L & !children %in% seen]
    if (length(children)) { seen <- c(seen, children); queue <- c(queue, children) }
  }
  unique(seen)
}

.worker_supervision_capability <- function(reset = FALSE,
                                           worker_factory = NULL) {
  if (isTRUE(reset)) {
    if (.diagnostics_callr_supervisor$references == 0L)
      .release_package_callr_supervisor()
    rm(list = ls(.diagnostics_supervision_cache),
       envir = .diagnostics_supervision_cache)
  }
  cached <- .diagnostics_supervision_cache$value
  if (!is.null(cached) && is.null(worker_factory)) return(cached)
  native <- .native_secure_capabilities()
  unsupported <- !isTRUE(native$unixDatagram) || !isTRUE(native$parentDeath) ||
    !isTRUE(native$secureFs) || !isTRUE(native$noReplace) ||
    !requireNamespace("callr", quietly = TRUE)
  if (unsupported) {
    result <- list(category = "unsupported", supervised = FALSE,
                   parentDeath = FALSE, treeKill = FALSE)
    if (is.null(worker_factory)) .diagnostics_supervision_cache$value <- result
    return(result)
  }
  parent_pid <- Sys.getpid()
  parent_start <- .native_process_start_token(parent_pid)
  if (!.diagnostics_scalar_character(parent_start)) {
    result <- list(category = "unsupported", supervised = FALSE,
                   parentDeath = FALSE, treeKill = FALSE)
    if (is.null(worker_factory)) .diagnostics_supervision_cache$value <- result
    return(result)
  }
  factory <- worker_factory %||% function(parent_pid, parent_start) {
    callr::r_bg(
      function(parent_pid, parent_start) {
        suppressPackageStartupMessages(library(shinyAssistantUI))
        if (!shinyAssistantUI:::.native_parent_guard_bootstrap(
          parent_pid, parent_start
        )) quit(status = 91L)
        Sys.sleep(0.05)
        TRUE
      },
      args = list(parent_pid = parent_pid, parent_start = parent_start),
      supervise = TRUE, stdout = "/dev/null", stderr = "/dev/null"
    )
  }
  before <- .owned_descendant_pids(Sys.getpid())
  process <- tryCatch(factory(parent_pid, parent_start), error = function(error) NULL)
  owned <- .capture_owned_processes(before)
  ok <- !is.null(process)
  if (ok) {
    tryCatch(process$wait(timeout = 2000), error = function(error) NULL)
    ok <- !isTRUE(tryCatch(process$is_alive(), error = function(error) TRUE)) &&
      identical(tryCatch(process$get_exit_status(), error = function(error) NA_integer_), 0L)
    if (isTRUE(tryCatch(process$is_alive(), error = function(error) FALSE))) {
      tryCatch(process$kill(), error = function(error) NULL)
      tryCatch(process$wait(timeout = 1000), error = function(error) NULL)
      ok <- FALSE
    }
    live_owned <- Filter(function(record) {
      dir.exists(file.path("/proc", record$pid))
    }, owned)
    if (ok && length(live_owned)) {
      existing <- vapply(.diagnostics_callr_supervisor$records, `[[`, integer(1), "pid")
      additions <- Filter(function(record) !record$pid %in% existing, live_owned)
      .diagnostics_callr_supervisor$records <- c(
        .diagnostics_callr_supervisor$records, additions
      )
    }
  }
  result <- list(category = if (ok) "ok" else "unsupported",
                 supervised = ok, parentDeath = ok, treeKill = ok)
  if (.diagnostics_callr_supervisor$references == 0L)
    .release_package_callr_supervisor()
  if (is.null(worker_factory)) .diagnostics_supervision_cache$value <- result
  result
}

.isolated_diagnostics_worker_main <- function(config, socket_path, ready_name,
                                               ready_tmp, parent_pid,
                                               parent_start_token) {
  if (!.native_parent_guard_bootstrap(parent_pid, parent_start_token))
    return(invisible(FALSE))
  root <- .native_fs_open_root(config$directory)
  if (is.null(root)) return(invisible(FALSE))
  socket <- .native_dgram_open(socket_path)
  if (is.null(socket)) return(invisible(FALSE))
  # Fixed child warmup removes byte-code/validator cold-start from the first
  # production flush. It performs no filesystem write and is not adaptive.
  for (index in seq_len(1000L)) {
    payload <- .diagnostics_benchmark_event(index)
    row <- .diagnostics_canonical_row(payload$event, payload$metrics,
                                      now = function() 1)
    .diagnostics_canonical_encode(row)
  }
  writer <- .new_diagnostics_writer(
    config, schedule = NULL, warn = function(category) NULL,
    elapsed = function() 0
  )
  on.exit(writer$close(), add = TRUE)
  ready <- .native_fs_atomic_write_at(root, ready_tmp, ready_name,
                                      charToRaw("ready\n"))
  if (!identical(ready, "ok")) return(invisible(FALSE))
  closing <- FALSE; queued_rows <- 0L; last_data <- .native_monotonic_ns()
  repeat {
    first <- .native_dgram_recv(socket, 32768L)
    if (is.null(first)) {
      if (queued_rows > 0L &&
          (.native_monotonic_ns() - last_data) / 1e9 >= 0.05) {
        writer$flush(); queued_rows <- 0L
      }
      Sys.sleep(0.002); next
    }
    last_data <- .native_monotonic_ns()
    frames <- list(first); frame_bytes <- length(first)
    while (length(frames) < 256L && frame_bytes < 8 * 1024^2) {
      next_frame <- .native_dgram_recv(socket, 32768L)
      if (is.null(next_frame)) break
      frames[[length(frames) + 1L]] <- next_frame
      frame_bytes <- frame_bytes + length(next_frame)
    }
    for (frame_raw in frames) {
      if (!length(frame_raw)) next
      frame <- tryCatch(unserialize(frame_raw), error = function(error) NULL)
      if (!is.list(frame) || is.null(names(frame)) ||
          !identical(frame$version, 1L) ||
          !.diagnostics_scalar_character(frame$kind)) next
      if (identical(frame$kind, "close") &&
          identical(names(frame), c("version", "kind"))) {
        closing <- TRUE; break
      }
      if (!identical(frame$kind, "rows") ||
          !identical(names(frame), c("version", "kind", "rows", "rotate")) ||
          !is.list(frame$rows) || length(frame$rows) > 100L ||
          !.diagnostics_scalar_logical(frame$rotate)) next
      canonical_rows <- lapply(frame$rows, function(item) {
        if (!is.list(item) || is.null(names(item))) return(NULL)
        if (identical(names(item), c("kind", "source", "event", "metrics", "ts")) &&
            identical(item$kind, "backend") &&
            !is.null(.diagnostics_safe_integer(item$ts))) {
          return(.diagnostics_safe_event(
            item$source, item$event, item$metrics, now = function() item$ts
          ))
        }
        if (identical(names(item), c("kind", "row")) &&
            identical(item$kind, "canonical") && is.list(item$row)) return(item$row)
        NULL
      })
      canonical_rows <- Filter(Negate(is.null), canonical_rows)
      if (queued_rows + length(canonical_rows) > config$buffer_max_events) {
        writer$flush(); queued_rows <- 0L
      }
      if (length(canonical_rows)) {
        writer$ingest_frontend_batch(list(
          version = 2L, schema = 1L, rows = canonical_rows
        ))
        queued_rows <- queued_rows + length(canonical_rows)
      }
      if (isTRUE(frame$rotate)) {
        writer$request_rotation(); writer$flush(); queued_rows <- 0L
      }
    }
    if (closing) {
      if (queued_rows > 0L) { writer$flush(); queued_rows <- 0L }
      break
    }
  }
  writer$close()
  invisible(TRUE)
}

.default_isolated_worker_factory <- function(config, socket_path, ready_name,
                                             ready_tmp, parent_pid,
                                             parent_start_token) {
  callr::r_bg(
    function(config, socket_path, ready_name, ready_tmp, parent_pid,
             parent_start_token) {
      suppressPackageStartupMessages(library(shinyAssistantUI))
      shinyAssistantUI:::.isolated_diagnostics_worker_main(
        config, socket_path, ready_name, ready_tmp, parent_pid,
        parent_start_token
      )
    },
    args = list(
      config = config, socket_path = socket_path, ready_name = ready_name,
      ready_tmp = ready_tmp, parent_pid = parent_pid,
      parent_start_token = parent_start_token
    ),
    supervise = TRUE, stdout = "/dev/null", stderr = "/dev/null"
  )
}

.wait_for_isolated_ready <- function(path, process, timeout = 2) {
  deadline <- Sys.time() + timeout
  repeat {
    if (file.exists(path)) return(TRUE)
    if (!isTRUE(tryCatch(process$is_alive(), error = function(error) FALSE))) return(FALSE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.005)
  }
}

.new_isolated_diagnostics_writer <- function(
    config, context = NULL, schedule = .diagnostics_default_schedule,
    supervision_probe = .worker_supervision_capability,
    worker_factory = .default_isolated_worker_factory,
    sender = NULL,
    ready_wait = .wait_for_isolated_ready) {
  normalized <- if (is.list(config) && isTRUE(config$sampled)) config else
    .normalize_diagnostics_config(config, sample_uniform = function() 0)
  capability <- tryCatch(supervision_probe(), error = function(error)
    list(category = "unsupported"))
  if (!isTRUE(normalized$enabled) || !identical(capability$category, "ok")) return(NULL)
  root_path <- normalizePath(path.expand(normalized$directory), winslash = "/",
                             mustWork = FALSE)
  if (!dir.exists(root_path) &&
      !dir.create(root_path, recursive = TRUE, mode = "0700", showWarnings = FALSE)) return(NULL)
  token <- .diagnostics_hex_token()
  if (is.null(token)) return(NULL)
  native <- .native_secure_capabilities()
  socket_path <- if (identical(native$platform, "linux")) {
    paste0("@saui-", token)
  } else {
    file.path(root_path, paste0(".writer-", token, ".sock"))
  }
  if (nchar(socket_path, type = "bytes") >= 104L) return(NULL)
  ready_name <- paste0(".writer-", token, ".ready")
  ready_tmp <- paste0(".writer-", token, ".ready-tmp")
  ready_path <- file.path(root_path, ready_name)
  parent_pid <- Sys.getpid(); parent_start <- .native_process_start_token(parent_pid)
  if (!.diagnostics_scalar_character(parent_start)) return(NULL)
  descendants_before <- .owned_descendant_pids(Sys.getpid())
  process <- tryCatch(worker_factory(
    normalized, socket_path, ready_name, ready_tmp, parent_pid, parent_start
  ), error = function(error) NULL)
  owned_processes <- .capture_owned_processes(descendants_before)
  if (is.null(process) || !isTRUE(tryCatch(
      ready_wait(ready_path, process), error = function(error) FALSE
    ))) {
    .shutdown_isolated_startup(process, descendants_before)
    unlink(c(ready_path, socket_path), force = TRUE)
    return(NULL)
  }
  unlink(ready_path, force = TRUE)
  if (is.null(sender)) {
    sender_target <- .native_dgram_client(socket_path)
    send_frame <- .native_dgram_send_handle
  } else {
    sender_target <- socket_path
    send_frame <- sender
  }
  if (is.null(sender_target)) {
    .shutdown_isolated_startup(process, descendants_before)
    return(NULL)
  }
  .diagnostics_callr_supervisor$references <-
    .diagnostics_callr_supervisor$references + 1L
  state <- new.env(parent = emptyenv())
  state$enabled <- TRUE; state$closed <- FALSE; state$category <- "ok"
  state$ring <- list(); state$timer_cancel <- NULL; state$dropped_events <- 0
  state$dropped_frames <- 0; state$sent_frames <- 0; state$sent_bytes <- 0
  state$max_frame_bytes <- 0; state$accepted_events <- 0
  state$rotation_requested <- FALSE; state$rotation_count <- 0
  state$process <- process; state$socket_path <- socket_path
  state$sender_target <- sender_target
  worker_alive <- function() isTRUE(tryCatch(state$process$is_alive(),
                                              error = function(error) FALSE))
  disable <- function(category) {
    state$enabled <- FALSE; state$category <- category
    state$dropped_events <- .diagnostics_saturating_add(
      state$dropped_events, length(state$ring)
    )
    state$ring <- list(); invisible(FALSE)
  }
  frame_for <- function(rows, rotate) serialize(
    list(version = 1L, kind = "rows", rows = rows, rotate = isTRUE(rotate)),
    NULL, ascii = FALSE, xdr = FALSE, version = 3L
  )
  drain_now <- NULL
  arm <- function() {
    if (!state$enabled || state$closed || !length(state$ring) ||
        !is.null(state$timer_cancel) || !is.function(schedule)) return(invisible(NULL))
    state$timer_cancel <- tryCatch(schedule(function() {
      state$timer_cancel <- NULL; drain_now()
    }, 0), error = function(error) NULL)
    invisible(NULL)
  }
  drain_now <- function() {
    state$timer_cancel <- NULL
    if (!state$enabled || state$closed || !length(state$ring)) return(FALSE)
    if (!worker_alive()) return(disable("closed"))
    count <- min(50L, length(state$ring)); bytes <- raw()
    repeat {
      rows <- state$ring[seq_len(count)]
      bytes <- tryCatch(frame_for(rows, state$rotation_requested),
                        error = function(error) raw())
      if (length(bytes) <= 32768L || count <= 1L) break
      count <- max(1L, floor(count / 2L))
    }
    state$ring <- state$ring[-seq_len(count)]
    if (!length(bytes) || length(bytes) > 32768L) {
      state$dropped_frames <- .diagnostics_saturating_add(state$dropped_frames)
      state$dropped_events <- .diagnostics_saturating_add(state$dropped_events, count)
      state$rotation_requested <- FALSE; arm(); return(FALSE)
    }
    result <- tryCatch(send_frame(state$sender_target, bytes), error = function(error)
      list(ok = FALSE, category = "io_error", bytes = 0L))
    state$max_frame_bytes <- max(state$max_frame_bytes, length(bytes))
    if (!isTRUE(result$ok)) {
      state$dropped_frames <- .diagnostics_saturating_add(state$dropped_frames)
      state$dropped_events <- .diagnostics_saturating_add(state$dropped_events, count)
      state$rotation_requested <- FALSE
      if (identical(result$category, "closed")) disable("closed") else arm()
      return(FALSE)
    }
    state$sent_frames <- .diagnostics_saturating_add(state$sent_frames)
    state$sent_bytes <- .diagnostics_saturating_add(state$sent_bytes, result$bytes)
    if (state$rotation_requested) {
      state$rotation_count <- .diagnostics_saturating_add(state$rotation_count)
      state$rotation_requested <- FALSE
    }
    arm(); TRUE
  }
  enqueue_row <- function(row) {
    if (!state$enabled || state$closed) return(FALSE)
    if (!worker_alive()) return(disable("closed"))
    if (length(state$ring) >= normalized$buffer_max_events) {
      state$dropped_events <- .diagnostics_saturating_add(state$dropped_events)
      return(FALSE)
    }
    state$ring[[length(state$ring) + 1L]] <- row
    state$accepted_events <- .diagnostics_saturating_add(state$accepted_events)
    arm(); TRUE
  }
  enqueue <- function(source, event, metrics = list(), thread_id = NULL,
                      run_id = NULL, flush_now = FALSE) {
    valid <- .diagnostics_scalar_character(source) &&
      source %in% c("backend", "frontend") &&
      .diagnostics_scalar_character(event) && is.list(metrics) &&
      (!length(metrics) || !is.null(names(metrics)))
    if (!valid) {
      state$dropped_events <- .diagnostics_saturating_add(state$dropped_events)
      return(FALSE)
    }
    enqueue_row(list(
      kind = "backend", source = source, event = event, metrics = metrics,
      ts = floor(as.numeric(Sys.time()))
    ))
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
      canonical <- if (exact) .diagnostics_canonical_row(
        row$event, row$metrics, now = function() row$ts
      ) else NULL
      if (is.null(canonical) || !enqueue_row(list(kind = "canonical", row = canonical)))
        accepted <- FALSE
    }
    accepted
  }
  request_rotation <- function() {
    if (!state$enabled || state$closed) return(FALSE)
    state$rotation_requested <- TRUE; TRUE
  }
  flush <- function() {
    if (!state$enabled || state$closed) return(FALSE)
    if (is.null(schedule)) drain_now() else { arm(); TRUE }
  }
  stop_timer <- function() {
    cancel <- state$timer_cancel; state$timer_cancel <- NULL
    if (is.function(cancel)) tryCatch(cancel(), error = function(error) NULL)
    TRUE
  }
  close_writer <- function() {
    if (state$closed) return(FALSE)
    stop_timer()
    # Bounded best-effort drain. Every datagram remains single-attempt.
    for (unused in seq_len(20L)) {
      if (!length(state$ring) || !state$enabled || !worker_alive()) break
      drain_now()
    }
    if (worker_alive()) {
      close_bytes <- serialize(list(version = 1L, kind = "close"), NULL,
                               ascii = FALSE, xdr = FALSE, version = 3L)
      tryCatch(send_frame(state$sender_target, close_bytes), error = function(error) NULL)
      tryCatch(state$process$wait(timeout = 2000), error = function(error) NULL)
      if (worker_alive()) {
        tryCatch(state$process$kill(), error = function(error) NULL)
        tryCatch(state$process$wait(timeout = 1000), error = function(error) NULL)
      }
    }
    .reap_owned_processes(owned_processes)
    .diagnostics_callr_supervisor$references <- max(
      0L, .diagnostics_callr_supervisor$references - 1L
    )
    .release_package_callr_supervisor()
    state$closed <- TRUE; state$enabled <- FALSE
    unlink(c(socket_path, ready_path), force = TRUE)
    TRUE
  }
  snapshot <- function() {
    alive <- worker_alive()
    pid <- suppressWarnings(as.integer(tryCatch(state$process$get_pid(),
                                                 error = function(error) NA_integer_)))
    list(
      enabled = state$enabled && alive, closed = state$closed,
      category = if (!alive && !state$closed) "closed" else state$category,
      worker_pid = pid, worker_alive = alive,
      active_descendants = if (alive) length(.owned_descendant_pids(pid)) else 0L,
      buffered_events = length(state$ring), written_events = state$accepted_events,
      dropped_events = state$dropped_events, dropped_frames = state$dropped_frames,
      sent_frames = state$sent_frames, sent_bytes = state$sent_bytes,
      max_frame_bytes = state$max_frame_bytes,
      rotation_count = state$rotation_count
    )
  }
  list(write_event = enqueue, ingest_frontend_batch = ingest,
       request_rotation = request_rotation, flush = flush,
       drain_now = drain_now, stop_timer = stop_timer,
       snapshot = snapshot, close = close_writer)
}

.shutdown_isolated_startup <- function(process, descendants_before = integer(),
                                       term_timeout_ms = 500L,
                                       kill_timeout_ms = 1000L) {
  owned <- .capture_owned_processes(descendants_before)
  alive <- function() !is.null(process) && isTRUE(tryCatch(
    process$is_alive(), error = function(error) FALSE
  ))
  if (alive()) {
    tryCatch(process$signal(15L), error = function(error) NULL)
    tryCatch(process$wait(timeout = term_timeout_ms), error = function(error) NULL)
  }
  if (alive()) {
    tryCatch(process$kill_tree(), error = function(error) NULL)
    tryCatch(process$wait(timeout = kill_timeout_ms), error = function(error) NULL)
  }
  if (alive()) {
    tryCatch(process$kill(), error = function(error) NULL)
    tryCatch(process$wait(timeout = kill_timeout_ms), error = function(error) NULL)
  }
  .reap_owned_processes(owned, timeout_ms = term_timeout_ms)
  tryCatch(.native_reap_children(kill_timeout_ms), error = function(error) NULL)
  .release_package_callr_supervisor()
  invisible(!alive())
}
