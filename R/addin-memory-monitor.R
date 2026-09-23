.memory_monitor_guard_state <- function(value) {
  if (!is.character(value) || length(value) != 1L || is.na(value)) return("unknown")
  if (value %in% c("hard_pending", "hard_idle", "hard")) return("hard")
  if (value %in% c("normal", "soft", "recovering", "disabled", "unknown")) return(value)
  "unknown"
}

.memory_monitor_safe_number <- function(value, fallback = 0) {
  safe <- .settings_safe_integer(value)
  if (is.null(safe)) as.numeric(fallback) else safe
}

.memory_monitor_time_ms <- function(value) {
  if (inherits(value, "POSIXt")) value <- as.numeric(value)
  if (!is.numeric(value) || length(value) != 1L ||
      !is.finite(value) || value <= 0 || value > 8640000000000) return(0)
  .memory_monitor_safe_number(floor(value * 1000))
}

.memory_monitor_percentage <- function(value) {
  if (!is.numeric(value) || length(value) != 1L ||
      !is.finite(value) || value < 0 || value > 100) return(NULL)
  as.numeric(value)
}

.memory_monitor_exact_open <- function(value) {
  is.list(value) && identical(names(value), c(
    "version", "ownerId", "openId", "visible", "revision", "sample"
  )) && (identical(value$version, 2L) || identical(value$version, 3L) ||
         identical(value$version, 4L)) &&
    !is.null(.settings_safe_integer(value$ownerId, positive = TRUE)) &&
    !is.null(.settings_safe_integer(value$openId, positive = TRUE)) &&
    .diagnostics_scalar_logical(value$visible) &&
    !is.null(.settings_safe_integer(value$revision)) && is.null(value$sample)
}

.new_memory_monitor_addin_plugin <- function(
    config, schedule = function(callback) {
      if (!requireNamespace("later", quietly = TRUE)) return(NULL)
      timer <- later::later(callback, delay = 0)
      function() .cancel_later_timer(timer)
    }) {
  normalized <- .normalize_memory_guard_config(config)
  thresholds <- list(
    softPssBytes = .memory_monitor_safe_number(normalized$soft_pss_bytes),
    hardPssBytes = .memory_monitor_safe_number(normalized$hard_pss_bytes),
    softRssBytes = .memory_monitor_safe_number(normalized$soft_rss_bytes),
    hardRssBytes = .memory_monitor_safe_number(normalized$hard_rss_bytes)
  )
  state <- new.env(parent = emptyenv())
  state$disposed <- FALSE
  state$revision <- 0
  state$latest <- NULL
  state$cgroup_previous <- NULL
  state$cgroup_deltas <- NULL
  state$owner_allocator <- 0
  state$serial <- 0L
  state$bindings <- new.env(hash = TRUE, parent = emptyenv())

  safe_session <- function(sample) {
    stat <- if (is.list(sample$cgroup_stat)) sample$cgroup_stat else list()
    events <- if (is.list(sample$cgroup_events)) sample$cgroup_events else list()
    pressure <- if (is.list(sample$cgroup_pressure)) sample$cgroup_pressure else list()
    counters <- list(
      limitEvents = .settings_safe_integer(events$max),
      oomEvents = .settings_safe_integer(events$oom),
      oomKillEvents = .settings_safe_integer(events$oom_kill)
    )
    at <- .memory_monitor_time_ms(sample$cgroup_captured_at)
    previous <- state$cgroup_previous
    deltas <- list(
      limitEventsDelta = NULL, oomEventsDelta = NULL, oomKillEventsDelta = NULL,
      intervalMs = NULL
    )
    if (at > 0 && !is.null(previous)) {
      if (identical(at, previous$at)) {
        # Fast RSS ticks reuse the same cgroup sample, not a new zero-event interval.
        deltas <- state$cgroup_deltas
      } else if (at > previous$at) {
        deltas$intervalMs <- .settings_safe_integer(at - previous$at, positive = TRUE)
        for (name in names(counters)) {
          current <- counters[[name]]
          before <- previous$counters[[name]]
          if (!is.null(current) && !is.null(before) && current >= before) {
            deltas[[paste0(name, "Delta")]] <- current - before
          }
        }
      }
    }
    if (at == 0) {
      state$cgroup_previous <- NULL
    } else if (is.null(previous) || !identical(at, previous$at)) {
      state$cgroup_previous <- list(at = at, counters = counters)
    }
    state$cgroup_deltas <- deltas
    limit_kind <- "unknown"
    if (!is.null(.settings_safe_integer(sample$cgroup_max_bytes))) {
      limit_kind <- "limited"
    } else if (identical(sample$cgroup_max_bytes, Inf)) {
      limit_kind <- "unlimited"
    }
    c(list(
      currentAvailable = !is.null(.settings_safe_integer(sample$cgroup_current_bytes)),
      limitKind = limit_kind,
      anonBytes = .settings_safe_integer(stat$anon),
      fileBytes = .settings_safe_integer(stat$file),
      inactiveFileBytes = .settings_safe_integer(stat$inactive_file),
      shmemBytes = .settings_safe_integer(stat$shmem),
      dirtyFileBytes = .settings_safe_integer(stat$file_dirty),
      writebackFileBytes = .settings_safe_integer(stat$file_writeback)
    ), counters, deltas, list(
      psiSomeAvg10 = .memory_monitor_percentage(pressure$some),
      psiFullAvg10 = .memory_monitor_percentage(pressure$full)
    ))
  }

  safe_sample <- function(sample, next_state) {
    cgroup_max <- sample$cgroup_max_bytes
    cgroup_limited <- is.numeric(cgroup_max) && length(cgroup_max) == 1L &&
      is.finite(cgroup_max) && cgroup_max > 0
    list(
      state = .memory_monitor_guard_state(next_state),
      pssBytes = .memory_monitor_safe_number(sample$pss_bytes),
      rssBytes = .memory_monitor_safe_number(sample$rss_bytes),
      treeRssBytes = .memory_monitor_safe_number(sample$tree_rss_bytes),
      treeProcessCount = .memory_monitor_safe_number(sample$tree_process_count),
      cgroupCurrentBytes = .memory_monitor_safe_number(sample$cgroup_current_bytes),
      cgroupMaxBytes = if (cgroup_limited) .memory_monitor_safe_number(cgroup_max) else 0,
      cgroupLimited = isTRUE(cgroup_limited),
      softPssBytes = thresholds$softPssBytes,
      hardPssBytes = thresholds$hardPssBytes,
      softRssBytes = thresholds$softRssBytes,
      hardRssBytes = thresholds$hardRssBytes,
      sampledAt = .memory_monitor_time_ms(sample$captured_at),
      treeSampledAt = .memory_monitor_time_ms(sample$tree_captured_at),
      cgroupSampledAt = .memory_monitor_time_ms(sample$cgroup_captured_at),
      session = safe_session(sample)
    )
  }

  send_frame <- function(binding) {
    if (state$disposed || is.null(binding) || isTRUE(binding$disposed) ||
        !isTRUE(binding$expanded) || isTRUE(binding$sent_for_open) ||
        is.null(state$latest)) return(invisible(FALSE))
    sample <- state$latest
    if (binding$version < 4L) sample$session <- NULL
    if (identical(binding$version, 2L)) {
      sample[c("sampledAt", "treeSampledAt", "cgroupSampledAt")] <- NULL
    }
    frame <- list(
      version = binding$version, ownerId = binding$owner_id, openId = binding$open_id,
      revision = state$revision, sample = sample
    )
    ok <- tryCatch({
      binding$session$sendCustomMessage(
        paste0(binding$input_id, ":memory-monitor-sample"), frame
      )
      TRUE
    }, error = function(e) FALSE)
    if (ok) {
      binding$sent_for_open <- TRUE
      binding$sent_revision <- state$revision
      return(invisible(TRUE))
    }
    if (!binding$retry_used && is.function(schedule)) {
      binding$retry_used <- TRUE
      tryCatch(schedule(function() {
        if (!binding$disposed && binding$expanded && !binding$sent_for_open)
          send_frame(binding)
      }), error = function(e) NULL)
    }
    invisible(FALSE)
  }

  dispose_binding <- function(key) {
    binding <- get0(key, envir = state$bindings, inherits = FALSE)
    if (is.null(binding) || isTRUE(binding$disposed)) return(invisible(FALSE))
    binding$disposed <- TRUE
    if (!is.null(binding$observer)) tryCatch(binding$observer$destroy(), error = function(e) NULL)
    binding$observer <- NULL; binding$session <- NULL
    if (exists(key, envir = state$bindings, inherits = FALSE)) rm(list = key, envir = state$bindings)
    invisible(TRUE)
  }

  observe <- function(sample, previous_state, next_state) {
    if (state$disposed || state$revision >= 2^53 - 1) return(invisible(FALSE))
    if (!is.list(sample)) sample <- list()
    state$revision <- state$revision + 1
    state$latest <- safe_sample(sample, next_state)
    for (key in ls(state$bindings, all.names = TRUE)) {
      binding <- get0(key, envir = state$bindings, inherits = FALSE)
      if (!is.null(binding) && isTRUE(binding$expanded) && !isTRUE(binding$sent_for_open))
        send_frame(binding)
    }
    invisible(TRUE)
  }

  bind <- function(session, input_id) {
    if (state$disposed || is.null(session) || !.diagnostics_scalar_character(input_id) ||
        state$owner_allocator >= 2^53 - 1) return(invisible(NULL))
    state$owner_allocator <- state$owner_allocator + 1
    state$serial <- state$serial + 1L
    key <- paste0("binding-", state$serial)
    binding <- new.env(parent = emptyenv())
    binding$session <- session; binding$input_id <- as.character(input_id)[[1L]]
    binding$owner_id <- state$owner_allocator; binding$open_id <- 0
    binding$version <- 4L
    binding$expanded <- FALSE; binding$sent_for_open <- FALSE
    binding$sent_revision <- 0; binding$retry_used <- FALSE
    binding$disposed <- FALSE; binding$observer <- NULL
    assign(key, binding, envir = state$bindings)
    binding$observer <- shiny::observeEvent(
      session$input[[paste0(binding$input_id, "_memory_monitor_visible")]],
      {
        message <- session$input[[paste0(binding$input_id, "_memory_monitor_visible")]]
        if (!.memory_monitor_exact_open(message) ||
            message$ownerId < binding$owner_id) return()
        if (message$ownerId > binding$owner_id) {
          # A fresh owner has accepted no server frame. Validate its exact
          # revision before mutating owner/open state so a future or stale echo
          # cannot consume the owner id.
          if (message$revision != 0) return()
          binding$owner_id <- message$ownerId
          state$owner_allocator <- max(state$owner_allocator, message$ownerId)
          binding$open_id <- 0
          binding$expanded <- FALSE
          binding$sent_for_open <- FALSE
          binding$sent_revision <- 0
          binding$retry_used <- FALSE
        } else if (message$revision != binding$sent_revision) {
          # `sent_revision` is advanced only after sendCustomMessage succeeds;
          # the browser must echo that exact accepted revision. Lower and
          # future revisions are both inert.
          return()
        }
        if (isTRUE(message$visible)) {
          if (message$openId <= binding$open_id) return()
          binding$version <- message$version
          binding$open_id <- message$openId
          binding$expanded <- TRUE
          binding$sent_for_open <- FALSE
          binding$retry_used <- FALSE
          send_frame(binding)
        } else if (message$openId == binding$open_id) {
          binding$expanded <- FALSE
          binding$sent_for_open <- FALSE
          binding$retry_used <- FALSE
        }
      },
      ignoreNULL = TRUE, ignoreInit = TRUE, domain = session
    )
    session$onSessionEnded(function() dispose_binding(key))
    list(
      config = list(version = 4L, ownerSeed = binding$owner_id,
                    lastRevision = binding$sent_revision),
      unbind = function() dispose_binding(key)
    )
  }

  dispose <- function() {
    if (state$disposed) return(FALSE)
    state$disposed <- TRUE
    for (key in ls(state$bindings, all.names = TRUE)) dispose_binding(key)
    state$latest <- NULL
    state$cgroup_previous <- NULL
    state$cgroup_deltas <- NULL
    TRUE
  }

  snapshot <- function() {
    keys <- ls(state$bindings, all.names = TRUE)
    list(
      disposed = state$disposed, bindings = length(keys),
      visible_bindings = sum(vapply(keys, function(key) {
        binding <- get0(key, envir = state$bindings, inherits = FALSE)
        !is.null(binding) && isTRUE(binding$expanded) && !binding$disposed
      }, logical(1))),
      revision = state$revision, has_latest = !is.null(state$latest),
      last_owner = state$owner_allocator
    )
  }

  list(
    config = function() list(version = 4L, protocol = "latest-snapshot"),
    observe = observe, bind = bind, dispose = dispose, snapshot = snapshot
  )
}
