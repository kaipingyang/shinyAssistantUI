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

.memory_monitor_exact_open <- function(value) {
  is.list(value) && identical(names(value), c(
    "version", "ownerId", "openId", "visible", "revision", "sample"
  )) && identical(value$version, 2L) &&
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
  state$owner_allocator <- 0
  state$serial <- 0L
  state$bindings <- new.env(hash = TRUE, parent = emptyenv())

  safe_sample <- function(sample, next_state) {
    cgroup_max <- sample$cgroup_max_bytes
    cgroup_limited <- is.numeric(cgroup_max) && length(cgroup_max) == 1L &&
      is.finite(cgroup_max) && cgroup_max > 0
    list(
      state = .memory_monitor_guard_state(next_state),
      pssBytes = .memory_monitor_safe_number(sample$pss_bytes),
      rssBytes = .memory_monitor_safe_number(sample$rss_bytes),
      cgroupCurrentBytes = .memory_monitor_safe_number(sample$cgroup_current_bytes),
      cgroupMaxBytes = if (cgroup_limited) .memory_monitor_safe_number(cgroup_max) else 0,
      cgroupLimited = isTRUE(cgroup_limited),
      softPssBytes = thresholds$softPssBytes,
      hardPssBytes = thresholds$hardPssBytes,
      softRssBytes = thresholds$softRssBytes,
      hardRssBytes = thresholds$hardRssBytes
    )
  }

  send_frame <- function(binding) {
    if (state$disposed || is.null(binding) || isTRUE(binding$disposed) ||
        !isTRUE(binding$expanded) || isTRUE(binding$sent_for_open) ||
        is.null(state$latest)) return(invisible(FALSE))
    frame <- list(
      version = 2L, ownerId = binding$owner_id, openId = binding$open_id,
      revision = state$revision, sample = state$latest
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
      config = list(version = 2L, ownerSeed = binding$owner_id,
                    lastRevision = binding$sent_revision),
      unbind = function() dispose_binding(key)
    )
  }

  dispose <- function() {
    if (state$disposed) return(FALSE)
    state$disposed <- TRUE
    for (key in ls(state$bindings, all.names = TRUE)) dispose_binding(key)
    state$latest <- NULL
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
    config = function() list(version = 2L, protocol = "latest-snapshot"),
    observe = observe, bind = bind, dispose = dispose, snapshot = snapshot
  )
}
