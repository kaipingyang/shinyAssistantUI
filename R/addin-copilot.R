# Addin-only copilot-api readiness manager. The external script owns launch
# mechanics; this file only performs health/readiness checks and publishes state.

.copilot_api_url <- function() "http://127.0.0.1:4141/v1/models"
.copilot_api_script <- function() path.expand("~/auto-start-copilot.sh")

.copilot_api_health <- function(url = .copilot_api_url(), timeout = 2) {
  old_timeout <- getOption("timeout")
  on.exit(options(timeout = old_timeout), add = TRUE)
  options(timeout = max(1, as.integer(timeout)))
  con <- NULL
  tryCatch({
    con <- base::url(url, open = "rb", encoding = "bytes")
    on.exit(try(close(con), silent = TRUE), add = TRUE)
    length(readBin(con, what = "raw", n = 1L)) > 0L
  }, warning = function(e) FALSE, error = function(e) FALSE)
}

.copilot_api_start_sequence <- function(script, timeout, poll_interval,
                                        health, launch,
                                        script_exists = file.exists,
                                        now = Sys.time, sleep = Sys.sleep) {
  if (health()) return(list(status = "ready", message = "copilot-api is ready"))
  if (!script_exists(script))
    return(list(status = "failed", message = paste0("Startup script not found: ", script)))
  launch_status <- tryCatch(launch(script), error = function(e) e)
  if (inherits(launch_status, "error"))
    return(list(status = "failed", message = conditionMessage(launch_status)))
  deadline <- now() + timeout
  repeat {
    if (health()) return(list(status = "ready", message = "copilot-api is ready"))
    if (now() >= deadline) break
    sleep(poll_interval)
  }
  list(status = "failed", message = "copilot-api did not become ready")
}

.copilot_api_worker <- function(script = .copilot_api_script(),
                                url = .copilot_api_url(), timeout = 30,
                                poll_interval = 0.25) {
  if (!requireNamespace("callr", quietly = TRUE))
    stop("The Claude addin needs the 'callr' package to start copilot-api.", call. = FALSE)
  callr::r_bg(
    func = function(script, url, timeout, poll_interval, sequence) {
      health <- function() {
        old_timeout <- getOption("timeout")
        on.exit(options(timeout = old_timeout), add = TRUE)
        options(timeout = 2L)
        con <- NULL
        tryCatch({
          con <- base::url(url, open = "rb", encoding = "bytes")
          on.exit(try(close(con), silent = TRUE), add = TRUE)
          length(readBin(con, what = "raw", n = 1L)) > 0L
        }, warning = function(e) FALSE, error = function(e) FALSE)
      }
      sequence(
        script = script,
        timeout = timeout,
        poll_interval = poll_interval,
        health = health,
        launch = function(path) suppressWarnings(system2(
          path, args = character(), stdout = FALSE, stderr = FALSE
        ))
      )
    },
    args = list(script = script, url = url, timeout = timeout,
                poll_interval = poll_interval,
                sequence = .copilot_api_start_sequence),
    supervise = FALSE
  )
}

.new_copilot_service <- function(auto_start = TRUE, publish,
                                 worker_factory = .copilot_api_worker,
                                 schedule = function(fn, delay) later::later(fn, delay = delay),
                                 poll_interval = 0.2) {
  stopifnot(is.function(publish), is.function(worker_factory), is.function(schedule))
  state <- new.env(parent = emptyenv())
  state$auto <- isTRUE(auto_start)
  state$generation <- 0L
  state$worker <- NULL
  state$disposed <- FALSE

  emit <- function(status, message = NULL, generation = state$generation) {
    if (state$disposed || !identical(generation, state$generation)) return(invisible(NULL))
    payload <- list(status = status, autoStart = state$auto)
    if (!is.null(message) && nzchar(as.character(message))) payload$message <- as.character(message)
    publish(payload)
    invisible(payload)
  }

  poll <- function(generation) {
    if (state$disposed || !identical(generation, state$generation)) return(invisible(NULL))
    worker <- state$worker
    if (is.null(worker)) return(invisible(NULL))
    alive <- tryCatch(isTRUE(worker$is_alive()), error = function(e) FALSE)
    if (alive) {
      schedule(function() poll(generation), poll_interval)
      return(invisible(NULL))
    }
    result <- tryCatch(worker$get_result(), error = function(e)
      list(status = "failed", message = conditionMessage(e)))
    status <- if (identical(result$status, "ready")) "ready" else "failed"
    emit(status, result$message %||% if (status == "ready") "copilot-api is ready" else "copilot-api startup failed",
         generation)
  }

  start <- function(force = FALSE) {
    state$generation <- state$generation + 1L
    generation <- state$generation
    if (!state$auto && !isTRUE(force)) {
      emit("disabled", generation = generation)
      return(invisible(NULL))
    }
    emit("checking", "Checking copilot-api", generation)
    # The worker performs the authoritative health check before invoking the
    # existing script. Starting it is non-blocking for Shiny's main process.
    emit("starting", "Starting copilot-api", generation)
    state$worker <- tryCatch(worker_factory(), error = function(e) e)
    if (inherits(state$worker, "error")) {
      emit("failed", conditionMessage(state$worker), generation)
      state$worker <- NULL
      return(invisible(NULL))
    }
    schedule(function() poll(generation), 0)
    invisible(NULL)
  }

  list(
    start = start,
    retry = function() start(force = TRUE),
    set_auto_start = function(value) {
      state$auto <- isTRUE(value)
      if (state$auto) start() else {
        state$generation <- state$generation + 1L
        emit("disabled", generation = state$generation)
      }
      invisible(state$auto)
    },
    dispose = function() {
      # Do not terminate the shared daemon or a launcher already in progress.
      state$disposed <- TRUE
      state$generation <- state$generation + 1L
      invisible(NULL)
    }
  )
}
