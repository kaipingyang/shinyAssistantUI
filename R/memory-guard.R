.memory_guard_gib <- function(value) as.numeric(value) * 1024^3

.memory_guard_default_config <- function() {
  list(
    enabled = TRUE,
    soft_pss_bytes = .memory_guard_gib(1),
    hard_pss_bytes = .memory_guard_gib(2),
    soft_rss_bytes = .memory_guard_gib(1.25),
    hard_rss_bytes = .memory_guard_gib(2.25),
    consecutive_samples = 2L,
    hysteresis = 0.8,
    cgroup_hard_ratio = 0.9,
    cgroup_min_headroom_bytes = .memory_guard_gib(1),
    active_interval = 1,
    idle_interval = 5,
    settle_delay = 2
  )
}

.normalize_memory_guard_config <- function(config = NULL) {
  defaults <- .memory_guard_default_config()
  if (!is.list(config)) config <- list()
  output <- defaults
  for (name in names(defaults)) {
    if (!is.null(config[[name]])) output[[name]] <- config[[name]]
  }
  output$enabled <- isTRUE(output$enabled)
  positive <- function(value, fallback) {
    value <- suppressWarnings(as.numeric(value)[[1L]])
    if (!is.finite(value) || value <= 0) fallback else value
  }
  output$soft_pss_bytes <- positive(output$soft_pss_bytes, defaults$soft_pss_bytes)
  output$hard_pss_bytes <- positive(output$hard_pss_bytes, defaults$hard_pss_bytes)
  output$soft_rss_bytes <- positive(output$soft_rss_bytes, defaults$soft_rss_bytes)
  output$hard_rss_bytes <- positive(output$hard_rss_bytes, defaults$hard_rss_bytes)
  if (output$hard_pss_bytes <= output$soft_pss_bytes) {
    output$hard_pss_bytes <- defaults$hard_pss_bytes
  }
  if (output$hard_rss_bytes <= output$soft_rss_bytes) {
    output$hard_rss_bytes <- defaults$hard_rss_bytes
  }
  output$consecutive_samples <- suppressWarnings(as.integer(
    output$consecutive_samples
  )[[1L]])
  if (is.na(output$consecutive_samples) || output$consecutive_samples < 1L) {
    output$consecutive_samples <- defaults$consecutive_samples
  }
  output$hysteresis <- suppressWarnings(as.numeric(output$hysteresis)[[1L]])
  if (!is.finite(output$hysteresis) || output$hysteresis <= 0 ||
      output$hysteresis >= 1) {
    output$hysteresis <- defaults$hysteresis
  }
  output$cgroup_hard_ratio <- suppressWarnings(as.numeric(
    output$cgroup_hard_ratio
  )[[1L]])
  if (!is.finite(output$cgroup_hard_ratio) || output$cgroup_hard_ratio <= 0 ||
      output$cgroup_hard_ratio > 1) {
    output$cgroup_hard_ratio <- defaults$cgroup_hard_ratio
  }
  output$cgroup_min_headroom_bytes <- suppressWarnings(as.numeric(
    output$cgroup_min_headroom_bytes
  )[[1L]])
  if (!is.finite(output$cgroup_min_headroom_bytes) ||
      output$cgroup_min_headroom_bytes < 0) {
    output$cgroup_min_headroom_bytes <- defaults$cgroup_min_headroom_bytes
  }
  for (name in c("active_interval", "idle_interval", "settle_delay")) {
    output[[name]] <- positive(output[[name]], defaults[[name]])
  }
  output
}


.new_memory_guard_gc_tracker <- function(gc_full) {
  if (!is.function(gc_full)) stop("gc_full must be a function", call. = FALSE)
  state <- new.env(parent = emptyenv())
  state$r_heap_after_gc_bytes <- 0
  state$guard_gc_count <- 0

  snapshot <- function() list(
    r_heap_after_gc_bytes = state$r_heap_after_gc_bytes,
    guard_gc_count = state$guard_gc_count
  )
  collect <- function() {
    result <- gc_full()
    state$guard_gc_count <- min(2^53 - 1, state$guard_gc_count + 1)
    if (is.matrix(result) && ncol(result) >= 2L) {
      used_mb <- suppressWarnings(as.numeric(result[, 2L]))
      if (length(used_mb) && all(is.finite(used_mb)) && all(used_mb >= 0)) {
        state$r_heap_after_gc_bytes <- min(
          2^53 - 1,
          round(sum(used_mb) * 1024^2)
        )
      }
    }
    invisible(result)
  }
  list(collect = collect, snapshot = snapshot)
}
.memory_read_lines <- function(path) {
  if (!file.exists(path)) return(character())
  tryCatch(readLines(path, warn = FALSE), error = function(error) character())
}

.memory_parse_kib_field <- function(lines, field) {
  match <- grep(paste0("^", field, ":[[:space:]]*"), lines, value = TRUE)
  if (!length(match)) return(NULL)
  value <- suppressWarnings(as.numeric(sub(
    "^[^:]+:[[:space:]]*([0-9]+).*$", "\\1", match[[1L]]
  )))
  if (!length(value) || !is.finite(value)) NULL else value * 1024
}

.memory_parse_scalar_file <- function(path, infinity = FALSE) {
  lines <- .memory_read_lines(path)
  if (!length(lines)) return(NULL)
  value <- trimws(lines[[1L]])
  if (isTRUE(infinity) && identical(value, "max")) return(Inf)
  number <- suppressWarnings(as.numeric(value))
  if (!length(number) || !is.finite(number) || number < 0) NULL else number
}

.memory_parse_events <- function(path) {
  lines <- .memory_read_lines(path)
  if (!length(lines)) return(list())
  output <- list()
  for (line in lines) {
    parts <- strsplit(trimws(line), "[[:space:]]+")[[1L]]
    if (length(parts) < 2L || !nzchar(parts[[1L]])) next
    value <- suppressWarnings(as.numeric(parts[[2L]]))
    if (is.finite(value)) output[[parts[[1L]]]] <- value
  }
  output
}

.memory_process_rss_bytes <- function(pid, proc_root) {
  status <- .memory_read_lines(file.path(proc_root, pid, "status"))
  if (!length(status)) return(NULL)
  .memory_parse_kib_field(status, "VmRSS")
}

.memory_process_children <- function(pid, proc_root) {
  task_dir <- file.path(proc_root, pid, "task")
  tids <- suppressWarnings(list.files(task_dir))
  if (!length(tids)) return(integer())
  out <- integer()
  for (tid in tids) {
    raw <- .memory_read_lines(file.path(task_dir, tid, "children"))
    if (!length(raw)) next
    parts <- unlist(strsplit(paste(raw, collapse = " "), "[[:space:]]+"), use.names = FALSE)
    parts <- parts[nzchar(parts)]
    if (!length(parts)) next
    kids <- suppressWarnings(as.integer(parts))
    out <- c(out, kids[is.finite(kids)])
  }
  unique(out)
}

# Sum VmRSS across the addin R process and its transitive children (in practice the
# Claude Code CLI and whatever it spawns). RSS is summed rather than PSS because
# summing PSS across processes is not meaningful; the result is an upper bound, since
# pages shared between the processes are counted once per process. Fails open to NULL.
.read_process_tree_rss <- function(pid, proc_root = "/proc",
                                   max_nodes = 64L, max_depth = 8L) {
  pid <- suppressWarnings(as.integer(pid)[[1L]])
  if (!is.finite(pid)) return(NULL)
  root_rss <- .memory_process_rss_bytes(pid, proc_root)
  if (is.null(root_rss)) return(NULL)

  total <- root_rss
  count <- 1L
  visited <- pid
  frontier <- .memory_process_children(pid, proc_root)
  depth <- 0L
  while (length(frontier) && depth < max_depth && count < max_nodes) {
    frontier <- setdiff(frontier, visited)
    if (!length(frontier)) break
    next_frontier <- integer()
    for (child in frontier) {
      if (count >= max_nodes) break
      visited <- c(visited, child)
      rss <- .memory_process_rss_bytes(child, proc_root)
      if (is.null(rss)) next
      total <- total + rss
      count <- count + 1L
      next_frontier <- c(next_frontier, .memory_process_children(child, proc_root))
    }
    frontier <- unique(next_frontier)
    depth <- depth + 1L
  }
  list(bytes = total, count = count)
}

.read_linux_memory_snapshot <- function(
    pid = Sys.getpid(),
    proc_root = "/proc",
    cgroup_root = "/sys/fs/cgroup",
    now = Sys.time,
    include_pss = TRUE,
    include_cgroup = TRUE,
    include_tree = TRUE) {
  pid <- suppressWarnings(as.integer(pid)[[1L]])
  process_dir <- file.path(proc_root, pid)
  rollup <- if (isTRUE(include_pss)) {
    .memory_read_lines(file.path(process_dir, "smaps_rollup"))
  } else {
    character()
  }
  status <- if (length(rollup)) character() else
    .memory_read_lines(file.path(process_dir, "status"))

  source <- "unavailable"
  rss <- pss <- private_dirty <- anonymous <- NULL
  if (length(rollup)) {
    source <- "smaps_rollup"
    rss <- .memory_parse_kib_field(rollup, "Rss")
    pss <- .memory_parse_kib_field(rollup, "Pss")
    private_dirty <- .memory_parse_kib_field(rollup, "Private_Dirty")
    anonymous <- .memory_parse_kib_field(rollup, "Anonymous")
  } else if (length(status)) {
    source <- "status"
    rss <- .memory_parse_kib_field(status, "VmRSS")
  }

  tree <- if (isTRUE(include_tree)) {
    .read_process_tree_rss(pid = pid, proc_root = proc_root)
  } else NULL
  cgroup_current <- cgroup_max <- NULL
  cgroup_events <- list()
  if (isTRUE(include_cgroup)) {
    cgroup_current <- .memory_parse_scalar_file(file.path(cgroup_root, "memory.current"))
    cgroup_max <- .memory_parse_scalar_file(file.path(cgroup_root, "memory.max"), infinity = TRUE)
    cgroup_events <- .memory_parse_events(file.path(cgroup_root, "memory.events"))
  }
  captured_at <- now()

  list(
    available = !is.null(pss) || !is.null(rss),
    source = source,
    pid = pid,
    captured_at = captured_at,
    tree_captured_at = if (!is.null(tree)) captured_at else NULL,
    cgroup_captured_at = if (!is.null(cgroup_current)) captured_at else NULL,
    rss_bytes = rss,
    pss_bytes = pss,
    tree_rss_bytes = tree$bytes,
    tree_process_count = tree$count,
    private_dirty_bytes = private_dirty,
    anonymous_bytes = anonymous,
    cgroup_current_bytes = cgroup_current,
    cgroup_max_bytes = cgroup_max,
    cgroup_events = cgroup_events
  )
}

.new_linux_memory_guard_sampler <- function(
    cgroup_every = 10L,
    pss_trigger_bytes = Inf,
    pid = Sys.getpid(),
    proc_root = "/proc",
    cgroup_root = "/sys/fs/cgroup",
    now = Sys.time) {
  cgroup_every <- suppressWarnings(as.integer(cgroup_every)[[1L]])
  if (is.na(cgroup_every) || cgroup_every < 1L) cgroup_every <- 10L
  pss_trigger_bytes <- suppressWarnings(as.numeric(pss_trigger_bytes)[[1L]])
  if (is.na(pss_trigger_bytes) || pss_trigger_bytes <= 0) pss_trigger_bytes <- Inf
  count <- 0L
  # Walking the process tree costs several /proc reads, so it is throttled on the
  # same cadence as cgroup and cached in between rather than sampled every tick.
  cached_expensive <- list(
    cgroup_current_bytes = NULL,
    cgroup_max_bytes = NULL,
    cgroup_events = list(),
    tree_rss_bytes = NULL,
    tree_process_count = NULL,
    tree_captured_at = NULL,
    cgroup_captured_at = NULL
  )
  function() {
    count <<- count + 1L
    refresh_cgroup <- count == 1L || (count %% cgroup_every) == 0L
    value <- .read_linux_memory_snapshot(
      pid = pid, proc_root = proc_root, cgroup_root = cgroup_root, now = now,
      include_pss = FALSE, include_cgroup = refresh_cgroup,
      include_tree = refresh_cgroup
    )
    rss <- value$rss_bytes
    if (is.numeric(rss) && length(rss) == 1L && is.finite(rss) &&
        rss >= pss_trigger_bytes) {
      tree_carry <- value[c("tree_rss_bytes", "tree_process_count", "tree_captured_at")]
      value <- .read_linux_memory_snapshot(
        pid = pid, proc_root = proc_root, cgroup_root = cgroup_root, now = now,
        include_pss = TRUE, include_cgroup = refresh_cgroup,
        include_tree = FALSE
      )
      value[names(tree_carry)] <- tree_carry
    }
    if (refresh_cgroup) {
      cached_expensive <<- value[names(cached_expensive)]
    } else {
      value[names(cached_expensive)] <- cached_expensive
    }
    value
  }
}

.memory_guard_explicit_operations <- c(
  "foreground", "compact", "resume", "reload"
)
.memory_guard_background_operations <- c(
  "auto_continue", "warmup", "proactive"
)
.memory_guard_model_operations <- c(
  .memory_guard_explicit_operations, .memory_guard_background_operations
)

.memory_guard_metric <- function(sample, config) {
  if (is.list(sample) && is.numeric(sample$pss_bytes) &&
      length(sample$pss_bytes) == 1L && is.finite(sample$pss_bytes)) {
    return(list(
      source = "pss", value = as.numeric(sample$pss_bytes),
      soft = config$soft_pss_bytes, hard = config$hard_pss_bytes
    ))
  }
  if (is.list(sample) && is.numeric(sample$rss_bytes) &&
      length(sample$rss_bytes) == 1L && is.finite(sample$rss_bytes)) {
    return(list(
      source = "rss", value = as.numeric(sample$rss_bytes),
      soft = config$soft_rss_bytes, hard = config$hard_rss_bytes
    ))
  }
  NULL
}

.memory_guard_cgroup_pressure <- function(sample, config) {
  current <- if (is.list(sample)) sample$cgroup_current_bytes else NULL
  maximum <- if (is.list(sample)) sample$cgroup_max_bytes else NULL
  valid_current <- is.numeric(current) && length(current) == 1L &&
    is.finite(current) && current >= 0
  valid_maximum <- is.numeric(maximum) && length(maximum) == 1L &&
    !is.na(maximum) && maximum > 0
  if (!valid_current || !valid_maximum) {
    return(list(known = FALSE, critical = FALSE, ratio = NULL, headroom_bytes = NULL))
  }
  if (is.infinite(maximum)) {
    return(list(known = TRUE, critical = FALSE, ratio = 0,
                headroom_bytes = Inf))
  }
  ratio <- current / maximum
  headroom <- max(0, maximum - current)
  list(
    known = TRUE,
    critical = ratio >= config$cgroup_hard_ratio ||
      headroom <= config$cgroup_min_headroom_bytes,
    ratio = ratio,
    headroom_bytes = headroom
  )
}

.memory_guard_busy <- function(value) {
  isTRUE(tryCatch(value$busy, error = function(error) FALSE))
}

# Whether a snapshot may defer a full collection. A pending usage probe is a
# lightweight IPC round-trip, not R computation, so it reports `busy` (which
# only sets the sampling cadence) without setting `gc_blocked`. Snapshots that
# predate the field keep the old meaning: busy defers GC.
.memory_guard_blocks_gc <- function(value) {
  blocked <- tryCatch(value$gc_blocked, error = function(error) NULL)
  if (is.null(blocked)) return(.memory_guard_busy(value))
  isTRUE(blocked)
}

.new_memory_pressure_guard <- function(
    sample,
    busy_snapshot,
    gc_full,
    schedule,
    config = NULL,
    on_observation = NULL) {
  stopifnot(
    is.function(sample), is.function(busy_snapshot),
    is.function(gc_full), is.function(schedule),
    is.null(on_observation) || is.function(on_observation)
  )
  config <- .normalize_memory_guard_config(config)
  state <- new.env(parent = emptyenv())
  state$level <- "normal"
  state$latest <- NULL
  state$metric <- NULL
  state$soft_count <- 0L
  state$hard_count <- 0L
  state$below_soft_count <- 0L
  state$gc_attempted <- FALSE
  state$settling <- FALSE
  state$disposed <- FALSE
  state$started <- FALSE
  state$generation <- 0L
  state$cancel_timer <- NULL
  state$peak_bytes <- 0

  cancel_timer <- function() {
    state$generation <- state$generation + 1L
    cancel <- state$cancel_timer
    state$cancel_timer <- NULL
    if (is.function(cancel)) tryCatch(cancel(), error = function(error) invisible(NULL))
    invisible(NULL)
  }

  schedule_callback <- function(callback, delay) {
    if (state$disposed) return(invisible(FALSE))
    cancel_timer()
    token <- state$generation
    state$cancel_timer <- schedule(function() {
      if (state$disposed || !identical(token, state$generation)) {
        return(invisible(NULL))
      }
      state$cancel_timer <- NULL
      callback()
      invisible(NULL)
    }, delay)
    invisible(TRUE)
  }

  take_sample <- function() {
    value <- tryCatch(sample(), error = function(error) list(
      available = FALSE, source = "error", error = conditionMessage(error)
    ))
    state$latest <- value
    state$metric <- .memory_guard_metric(value, config)
    if (!is.null(state$metric)) {
      state$peak_bytes <- max(state$peak_bytes, state$metric$value)
    }
    state$metric
  }

  notify_observation <- function(previous_state) {
    if (!is.function(on_observation)) return(invisible(NULL))
    tryCatch(
      on_observation(state$latest, previous_state, state$level),
      error = function(error) invisible(NULL)
    )
    invisible(NULL)
  }

  reset_episode <- function(level = "normal") {
    state$level <- level
    state$soft_count <- 0L
    state$hard_count <- 0L
    state$below_soft_count <- 0L
    state$gc_attempted <- FALSE
    state$settling <- FALSE
    invisible(NULL)
  }

  finish_settle <- function() {
    if (state$disposed || !identical(state$level, "hard_pending")) {
      return(invisible(NULL))
    }
    # Settling only reads metrics; a newly busy turn must not strand this episode.
    state$settling <- FALSE
    previous_state <- state$level
    sampled <- FALSE
    on.exit({
      if (sampled) notify_observation(previous_state)
      if (is.null(state$cancel_timer)) schedule_tick()
    }, add = TRUE)
    metric <- take_sample()
    sampled <- TRUE
    if (is.null(metric)) {
      state$level <- "hard_idle"
      return(invisible(NULL))
    }
    if (metric$value < metric$hard * config$hysteresis) {
      recovered_level <- if (metric$value >= metric$soft) "soft" else "normal"
      reset_episode(recovered_level)
    } else {
      state$level <- "hard_idle"
    }
    invisible(NULL)
  }

  begin_settle <- function() {
    if (state$disposed || state$settling || state$gc_attempted ||
        !identical(state$level, "hard_pending")) {
      return(invisible(FALSE))
    }
    if (.memory_guard_blocks_gc(busy_snapshot())) return(invisible(FALSE))
    state$gc_attempted <- TRUE
    tryCatch(gc_full(), error = function(error) invisible(NULL))
    state$settling <- TRUE
    schedule_callback(finish_settle, config$settle_delay)
  }

  observe <- function() {
    if (state$disposed || !config$enabled || state$settling) {
      return(invisible(FALSE))
    }
    previous_state <- state$level
    sampled <- FALSE
    on.exit(if (sampled) notify_observation(previous_state), add = TRUE)
    metric <- take_sample()
    sampled <- TRUE
    if (is.null(metric)) return(invisible(FALSE))
    if (identical(state$level, "hard_idle")) {
      if (metric$value < metric$hard * config$hysteresis) {
        recovered_level <- if (metric$value >= metric$soft) "soft" else "normal"
        reset_episode(recovered_level)
      }
      return(invisible(TRUE))
    }

    if (metric$value >= metric$hard) {
      state$hard_count <- state$hard_count + 1L
      state$soft_count <- state$soft_count + 1L
      state$below_soft_count <- 0L
      if (state$hard_count >= config$consecutive_samples) {
        state$level <- "hard_pending"
        begin_settle()
      } else if (state$soft_count >= config$consecutive_samples) {
        state$level <- "soft"
      }
      return(invisible(TRUE))
    }

    if (identical(state$level, "hard_pending")) {
      begin_settle()
      return(invisible(TRUE))
    }
    state$hard_count <- 0L
    if (metric$value >= metric$soft) {
      state$soft_count <- state$soft_count + 1L
      state$below_soft_count <- 0L
      if (state$soft_count >= config$consecutive_samples) state$level <- "soft"
    } else {
      state$soft_count <- 0L
      if (identical(state$level, "soft") &&
          metric$value < metric$soft * config$hysteresis) {
        state$below_soft_count <- state$below_soft_count + 1L
        if (state$below_soft_count >= config$consecutive_samples) {
          reset_episode("normal")
        }
      } else {
        state$below_soft_count <- 0L
      }
    }
    invisible(TRUE)
  }

  schedule_tick <- NULL
  schedule_tick <- function(delay = NULL) {
    if (state$disposed || !state$started || state$settling) {
      return(invisible(FALSE))
    }
    busy <- .memory_guard_busy(busy_snapshot())
    delay <- delay %||% if (busy) config$active_interval else config$idle_interval
    schedule_callback(function() {
      observe()
      if (!state$settling) schedule_tick()
    }, delay)
  }

  list(
    start = function() {
      if (state$disposed || !config$enabled) return(invisible(FALSE))
      if (state$started) return(invisible(TRUE))
      state$started <- TRUE
      schedule_tick(0)
      invisible(TRUE)
    },
    observe = observe,
    on_idle = function() {
      if (state$disposed || !identical(state$level, "hard_pending")) {
        return(invisible(FALSE))
      }
      begin_settle()
    },
    allows = function(operation) {
      operation <- as.character(operation %||% "")[[1L]]
      blocked <- state$level %in% c("hard_pending", "hard_idle")
      if (!blocked || !operation %in% .memory_guard_model_operations) return(TRUE)
      if (operation %in% .memory_guard_background_operations) return(FALSE)
      pressure <- .memory_guard_cgroup_pressure(state$latest, config)
      isTRUE(pressure$known) && !isTRUE(pressure$critical)
    },
    snapshot = function() list(
      state = state$level,
      latest = state$latest,
      metric = state$metric,
      cgroup_pressure = .memory_guard_cgroup_pressure(state$latest, config),
      peak_bytes = state$peak_bytes,
      soft_count = state$soft_count,
      hard_count = state$hard_count,
      gc_attempted = state$gc_attempted,
      settling = state$settling,
      disposed = state$disposed,
      started = state$started,
      generation = state$generation,
      config = config
    ),
    dispose = function() {
      if (state$disposed) return(invisible(NULL))
      state$disposed <- TRUE
      state$started <- FALSE
      cancel_timer()
      invisible(NULL)
    }
  )
}
