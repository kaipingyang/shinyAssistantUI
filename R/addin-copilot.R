# copilot-api is a shared external daemon. The addin owns only local readiness
# state; disabling or disposing the addin must never terminate the daemon.

.copilot_api_host <- function() "127.0.0.1"
.copilot_api_port <- function() 4141L
.copilot_api_script <- function() path.expand("~/auto-start-copilot.sh")

.copilot_api_port_open <- function(host = .copilot_api_host(),
                                   port = .copilot_api_port(),
                                   timeout = 0.1) {
  connection <- NULL
  tryCatch({
    connection <- socketConnection(
      host = host,
      port = as.integer(port),
      open = "a+b",
      blocking = TRUE,
      timeout = max(0.01, as.numeric(timeout))
    )
    TRUE
  }, warning = function(e) FALSE, error = function(e) FALSE,
  finally = {
    if (!is.null(connection)) try(close(connection), silent = TRUE)
  })
}

.copilot_monotonic_now <- function() {
  unname(proc.time()[["elapsed"]])
}

.copilot_script_executable <- function(path) {
  isTRUE(file.access(path, mode = 1L) == 0L)
}

.copilot_manual_guidance <- function(reason) {
  paste0(
    reason,
    "\nStart it manually with ~/auto-start-copilot.sh,",
    "\ncheck ~/.copilot-api.log, then click Retry."
  )
}

.copilot_api_launch <- function(script = .copilot_api_script(),
                                script_exists = file.exists,
                                script_executable = .copilot_script_executable,
                                system2_fn = system2) {
  if (!isTRUE(script_exists(script))) {
    stop("Startup script not found: ", script, call. = FALSE)
  }
  if (!isTRUE(script_executable(script))) {
    stop("Startup script is not executable: ", script, call. = FALSE)
  }

  status <- suppressWarnings(system2_fn(
    command = script,
    args = character(),
    stdout = FALSE,
    stderr = FALSE,
    wait = FALSE
  ))
  if (length(status) && !is.na(status[[1L]]) && status[[1L]] != 0L) {
    stop("Startup script could not be launched (status ", status[[1L]], ")", call. = FALSE)
  }
  invisible(status)
}

.new_copilot_service <- function(
    auto_start = TRUE,
    publish,
    script = .copilot_api_script(),
    health = function() .copilot_api_port_open(),
    launch = function() .copilot_api_launch(script),
    script_exists = file.exists,
    script_executable = .copilot_script_executable,
    schedule = function(fn, delay) later::later(fn, delay = delay),
    now = .copilot_monotonic_now,
    timeout = 30,
    poll_interval = 0.2) {
  stopifnot(
    is.function(publish), is.function(health), is.function(launch),
    is.function(script_exists), is.function(script_executable),
    is.function(schedule), is.function(now),
    length(timeout) == 1L, is.finite(timeout), timeout >= 0,
    length(poll_interval) == 1L, is.finite(poll_interval), poll_interval >= 0
  )

  state <- new.env(parent = emptyenv())
  state$auto <- isTRUE(auto_start)
  state$generation <- 0L
  state$deadline <- NULL
  state$disposed <- FALSE

  emit <- function(status, message = NULL, generation = state$generation) {
    if (state$disposed || !identical(generation, state$generation)) {
      return(invisible(NULL))
    }
    payload <- list(status = status, autoStart = state$auto)
    if (!is.null(message) && nzchar(as.character(message))) {
      payload$message <- as.character(message)
    }
    publish(payload)
    invisible(payload)
  }

  safe_health <- function() {
    tryCatch(isTRUE(health()), warning = function(e) FALSE, error = function(e) FALSE)
  }

  timeout_message <- function() {
    seconds <- format(timeout, trim = TRUE, scientific = FALSE)
    .copilot_manual_guidance(paste0(
      "copilot-api did not become ready within ", seconds, " seconds."
    ))
  }

  poll <- function(generation) {
    if (state$disposed || !identical(generation, state$generation)) {
      return(invisible(NULL))
    }
    deadline <- state$deadline
    if (is.null(deadline)) return(invisible(NULL))

    # Deadline first: once an event-loop turn begins at/after the deadline, a
    # late health response cannot move this generation back to ready.
    if (now() >= deadline) {
      state$deadline <- NULL
      emit("failed", timeout_message(), generation)
      return(invisible(NULL))
    }
    if (safe_health()) {
      state$deadline <- NULL
      emit("ready", "copilot-api is ready", generation)
      return(invisible(NULL))
    }
    schedule(function() poll(generation), poll_interval)
    invisible(NULL)
  }

  start <- function(force = FALSE) {
    if (state$disposed) return(invisible(NULL))
    state$generation <- state$generation + 1L
    generation <- state$generation
    state$deadline <- NULL

    if (!state$auto && !isTRUE(force)) {
      emit("disabled", generation = generation)
      return(invisible(NULL))
    }

    emit("checking", "Checking copilot-api", generation)
    if (safe_health()) {
      emit("ready", "copilot-api is ready", generation)
      return(invisible(NULL))
    }

    failure <- NULL
    if (!isTRUE(script_exists(script))) {
      failure <- paste0("Startup script not found: ", script)
    } else if (!isTRUE(script_executable(script))) {
      failure <- paste0("Startup script is not executable: ", script)
    }
    if (!is.null(failure)) {
      emit("failed", .copilot_manual_guidance(failure), generation)
      return(invisible(NULL))
    }

    # The parent establishes the bounded lifetime before accepting the launch.
    # system2(wait = FALSE) starts the Bash/Node launcher directly: no nested R,
    # callr worker, project .Rprofile, or second renv activation is involved.
    state$deadline <- now() + timeout
    launch_result <- tryCatch(launch(), error = function(e) e)
    if (inherits(launch_result, "error")) {
      state$deadline <- NULL
      emit(
        "failed",
        .copilot_manual_guidance(conditionMessage(launch_result)),
        generation
      )
      return(invisible(NULL))
    }

    emit("starting", "Starting copilot-api", generation)
    schedule(function() poll(generation), 0)
    invisible(NULL)
  }

  list(
    start = start,
    retry = function() start(force = TRUE),
    set_auto_start = function(value) {
      if (state$disposed) return(invisible(state$auto))
      state$auto <- isTRUE(value)
      if (state$auto) {
        start()
      } else {
        state$generation <- state$generation + 1L
        state$deadline <- NULL
        emit("disabled", generation = state$generation)
      }
      invisible(state$auto)
    },
    dispose = function() {
      # Do not terminate the shared daemon or a launcher already in progress.
      state$disposed <- TRUE
      state$generation <- state$generation + 1L
      state$deadline <- NULL
      invisible(NULL)
    }
  )
}


# Addin-only binding for the copilot service. The generic assistant server only
# receives the opaque config snapshot attached to the handler; it does not own
# this lifecycle or understand these channels.
.new_copilot_addin_plugin <- function(
    auto_start = TRUE,
    persist_auto_start = function(value) invisible(value),
    service_factory = function(auto_start, publish) {
      .new_copilot_service(auto_start = auto_start, publish = publish)
    }) {
  stopifnot(is.function(persist_auto_start), is.function(service_factory))

  state <- new.env(parent = emptyenv())
  state$latest <- list(
    status = if (isTRUE(auto_start)) "checking" else "disabled",
    autoStart = isTRUE(auto_start)
  )
  state$session <- NULL
  state$input_id <- NULL
  state$started <- FALSE
  state$bound <- FALSE
  state$disposed <- FALSE

  publish <- function(value) {
    if (state$disposed || !is.list(value)) return(invisible(NULL))
    state$latest <- value
    if (!is.null(state$session) && !is.null(state$input_id)) {
      state$session$sendCustomMessage(
        paste0(state$input_id, ":copilot-service-status"), value
      )
    }
    invisible(value)
  }

  service <- service_factory(isTRUE(auto_start), publish)
  required_methods <- c("start", "retry", "set_auto_start", "dispose")
  if (!is.list(service) || !all(vapply(
    required_methods, function(name) is.function(service[[name]]), logical(1)
  ))) {
    stop("`service_factory` must return start/retry/set_auto_start/dispose functions.",
         call. = FALSE)
  }

  bind <- function(session, input_id) {
    if (state$disposed || state$bound) return(invisible(FALSE))
    state$session <- session
    state$input_id <- as.character(input_id)[[1L]]
    state$bound <- TRUE

    shiny::observeEvent(
      session$input[[paste0(state$input_id, "_copilot_service_ready")]],
      {
        if (state$disposed) return()
        if (!state$started) {
          state$started <- TRUE
          service$start()
        } else {
          publish(state$latest)
        }
      },
      ignoreNULL = TRUE,
      ignoreInit = TRUE
    )
    shiny::observeEvent(
      session$input[[paste0(state$input_id, "_copilot_auto_start")]],
      {
        if (state$disposed) return()
        msg <- session$input[[paste0(state$input_id, "_copilot_auto_start")]]
        value <- if (is.list(msg)) msg$value else msg
        value <- isTRUE(value)
        tryCatch(persist_auto_start(value), error = function(e) NULL)
        service$set_auto_start(value)
      },
      ignoreNULL = TRUE,
      ignoreInit = TRUE
    )
    shiny::observeEvent(
      session$input[[paste0(state$input_id, "_copilot_retry")]],
      {
        if (!state$disposed) service$retry()
      },
      ignoreNULL = TRUE,
      ignoreInit = TRUE
    )
    session$onSessionEnded(function() {
      if (state$disposed) return(invisible(NULL))
      state$disposed <- TRUE
      service$dispose()
      invisible(NULL)
    })
    invisible(TRUE)
  }

  list(
    config = function() list(version = 1L, state = state$latest),
    bind = bind
  )
}
