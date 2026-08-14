new_fake_scheduler <- function() {
  state <- new.env(parent = emptyenv())
  state$queue <- list()
  state$schedule <- function(fn, delay) {
    state$queue[[length(state$queue) + 1L]] <- list(fn = fn, delay = delay)
    invisible(NULL)
  }
  state$run_next <- function() {
    stopifnot(length(state$queue) > 0L)
    item <- state$queue[[1L]]
    state$queue <- state$queue[-1L]
    item$fn()
    invisible(item$delay)
  }
  state
}

statuses <- function(events) vapply(events, `[[`, character(1), "status")

manual_guidance_pattern <- "Start it manually with ~/auto-start-copilot.sh"

test_that("copilot readiness uses a prompt loopback TCP port probe", {
  skip_if_not_installed("httpuv")
  port <- httpuv::randomPort()

  started <- .copilot_monotonic_now()
  expect_false(.copilot_api_port_open(port = port, timeout = 0.1))
  expect_lt(.copilot_monotonic_now() - started, 0.5)

  listener <- serverSocket(port = port)
  on.exit(try(close(listener), silent = TRUE), add = TRUE)
  expect_true(.copilot_api_port_open(port = port, timeout = 0.1))
})

test_that("copilot service health-checks before launching", {
  events <- list()
  launches <- 0L
  service <- .new_copilot_service(
    auto_start = TRUE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    health = function() TRUE,
    launch = function() launches <<- launches + 1L,
    schedule = function(fn, delay) stop("ready service must not schedule")
  )

  service$start()

  expect_identical(statuses(events), c("checking", "ready"))
  expect_identical(launches, 0L)
  expect_true(all(vapply(events, `[[`, logical(1), "autoStart")))
})

test_that("copilot service launches directly then polls until ready", {
  events <- list()
  scheduler <- new_fake_scheduler()
  checks <- 0L
  launches <- 0L
  service <- .new_copilot_service(
    auto_start = TRUE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    health = function() {
      checks <<- checks + 1L
      checks >= 3L
    },
    launch = function() launches <<- launches + 1L,
    schedule = scheduler$schedule,
    now = function() 10,
    timeout = 30,
    poll_interval = 0.25
  )

  service$start()
  expect_identical(statuses(events), c("checking", "starting"))
  expect_identical(launches, 1L)
  expect_length(scheduler$queue, 1L)

  scheduler$run_next()
  expect_identical(tail(statuses(events), 1L), "starting")
  expect_length(scheduler$queue, 1L)

  scheduler$run_next()
  expect_identical(tail(statuses(events), 1L), "ready")
  expect_length(scheduler$queue, 0L)
})

test_that("parent-owned deadline fails with manual recovery guidance", {
  events <- list()
  scheduler <- new_fake_scheduler()
  clock <- 100
  checks <- 0L
  service <- .new_copilot_service(
    publish = function(value) events[[length(events) + 1L]] <<- value,
    health = function() { checks <<- checks + 1L; FALSE },
    launch = function() invisible(0L),
    schedule = scheduler$schedule,
    now = function() clock,
    timeout = 5
  )

  service$start()
  expect_identical(statuses(events), c("checking", "starting"))
  expect_identical(checks, 1L)

  clock <- 105
  scheduler$run_next()
  expect_identical(tail(statuses(events), 1L), "failed")
  expect_identical(checks, 1L) # deadline-first: no health probe after expiry
  expect_match(tail(events, 1L)[[1L]]$message,
               "did not become ready within 5 seconds", fixed = TRUE)
  expect_match(tail(events, 1L)[[1L]]$message,
               manual_guidance_pattern, fixed = TRUE)
  expect_match(tail(events, 1L)[[1L]]$message,
               "check ~/.copilot-api.log, then click Retry", fixed = TRUE)
  expect_length(scheduler$queue, 0L)
})

test_that("missing, non-executable, and launch errors fail without polling", {
  cases <- list(
    missing = list(exists = FALSE, executable = TRUE,
                   pattern = "Startup script not found"),
    non_executable = list(exists = TRUE, executable = FALSE,
                          pattern = "Startup script is not executable"),
    launch_error = list(exists = TRUE, executable = TRUE,
                        pattern = "fixture launch failed")
  )

  for (case in cases) {
    events <- list()
    scheduler <- new_fake_scheduler()
    service <- .new_copilot_service(
      publish = function(value) events[[length(events) + 1L]] <<- value,
      health = function() FALSE,
      launch = if (identical(case$pattern, "fixture launch failed"))
        function() stop("fixture launch failed") else function() invisible(0L),
      script_exists = function(path) case$exists,
      script_executable = function(path) case$executable,
      schedule = scheduler$schedule
    )

    service$start()
    expect_identical(tail(statuses(events), 1L), "failed")
    expect_match(tail(events, 1L)[[1L]]$message, case$pattern, fixed = TRUE)
    expect_match(tail(events, 1L)[[1L]]$message,
                 manual_guidance_pattern, fixed = TRUE)
    expect_length(scheduler$queue, 0L)
  }
})

test_that("retry supersedes stale polls and can recover", {
  events <- list()
  scheduler <- new_fake_scheduler()
  ready <- FALSE
  launches <- 0L
  service <- .new_copilot_service(
    publish = function(value) events[[length(events) + 1L]] <<- value,
    health = function() ready,
    launch = function() launches <<- launches + 1L,
    schedule = scheduler$schedule,
    now = function() 0
  )

  service$start()
  service$retry()
  expect_identical(launches, 2L)
  expect_length(scheduler$queue, 2L)

  ready <- TRUE
  scheduler$run_next() # generation 1: stale, no publication
  expect_identical(tail(statuses(events), 1L), "starting")
  scheduler$run_next() # generation 2
  expect_identical(tail(statuses(events), 1L), "ready")
})

test_that("disabled and disposed services never leave active polling", {
  events <- list()
  scheduler <- new_fake_scheduler()
  launches <- 0L
  service <- .new_copilot_service(
    auto_start = FALSE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    health = function() FALSE,
    launch = function() launches <<- launches + 1L,
    schedule = scheduler$schedule
  )

  service$start()
  expect_identical(statuses(events), "disabled")
  expect_identical(launches, 0L)

  service$set_auto_start(TRUE)
  expect_identical(launches, 1L)
  expect_length(scheduler$queue, 1L)
  before_dispose <- length(events)
  service$dispose()
  scheduler$run_next()
  expect_length(events, before_dispose)
  expect_length(scheduler$queue, 0L)

  service$retry()
  service$start()
  service$set_auto_start(FALSE)
  service$set_auto_start(TRUE)
  expect_identical(launches, 1L)
  expect_length(events, before_dispose)
  expect_length(scheduler$queue, 0L)
})

test_that("direct launcher validates executable and requests asynchronous system2", {
  calls <- list()
  fake_system2 <- function(command, args, stdout, stderr, wait) {
    calls[[length(calls) + 1L]] <<- list(
      command = command, args = args, stdout = stdout, stderr = stderr, wait = wait
    )
    invisible(0L)
  }

  expect_error(
    .copilot_api_launch(
      "/missing/start.sh",
      script_exists = function(path) FALSE,
      system2_fn = fake_system2
    ),
    "Startup script not found", fixed = TRUE
  )
  expect_error(
    .copilot_api_launch(
      "/not-executable/start.sh",
      script_exists = function(path) TRUE,
      script_executable = function(path) FALSE,
      system2_fn = fake_system2
    ),
    "not executable", fixed = TRUE
  )

  .copilot_api_launch(
    "/fixture/start.sh",
    script_exists = function(path) TRUE,
    script_executable = function(path) TRUE,
    system2_fn = fake_system2
  )
  expect_length(calls, 1L)
  expect_identical(calls[[1L]], list(
    command = "/fixture/start.sh",
    args = character(),
    stdout = FALSE,
    stderr = FALSE,
    wait = FALSE
  ))
})

test_that("monotonic startup clock returns finite nondecreasing seconds", {
  first <- .copilot_monotonic_now()
  second <- .copilot_monotonic_now()
  expect_true(is.finite(first))
  expect_gte(second, first)
})


test_that("direct launcher returns promptly and leaves no fixture process or lock", {
  skip_if(Sys.which("flock") == "", "flock is required for the launcher fixture")

  fixture_dir <- tempfile("copilot-launch-fixture-")
  dir.create(fixture_dir)
  script <- file.path(fixture_dir, "start.sh")
  marker <- file.path(fixture_dir, "done")
  pid_file <- file.path(fixture_dir, "pid")
  lock_file <- file.path(fixture_dir, "launcher.lock")
  writeLines(c(
    "#!/bin/sh",
    paste("exec 9>", shQuote(lock_file), sep = ""),
    "flock -n 9 || exit 9",
    paste("printf '%s' \"$$\" >", shQuote(pid_file)),
    "sleep 0.3",
    paste("printf done >", shQuote(marker))
  ), script)
  Sys.chmod(script, mode = "0755")

  started <- .copilot_monotonic_now()
  .copilot_api_launch(script)
  elapsed <- .copilot_monotonic_now() - started
  expect_lt(elapsed, 0.25)

  deadline <- .copilot_monotonic_now() + 3
  while (!file.exists(marker) && .copilot_monotonic_now() < deadline) Sys.sleep(0.02)
  expect_true(file.exists(marker))
  expect_true(file.exists(pid_file))

  pid <- suppressWarnings(as.integer(readLines(pid_file, warn = FALSE)[[1L]]))
  Sys.sleep(0.1)
  expect_false(file.exists(file.path("/proc", as.character(pid))))
  expect_identical(
    suppressWarnings(system2(Sys.which("flock"), c("-n", lock_file, "-c", "true"))),
    0L
  )
})


test_that("copilot addin plugin starts only after its frontend channel is ready", {
  calls <- new.env(parent = emptyenv())
  calls$start <- 0L
  calls$retry <- 0L
  calls$auto <- logical()
  calls$dispose <- 0L
  persisted <- logical()
  publish_from_service <- NULL

  service_factory <- function(auto_start, publish) {
    publish_from_service <<- publish
    list(
      start = function() {
        calls$start <- calls$start + 1L
        publish(list(status = "starting", autoStart = isTRUE(auto_start)))
      },
      retry = function() calls$retry <- calls$retry + 1L,
      set_auto_start = function(value) calls$auto <- c(calls$auto, isTRUE(value)),
      dispose = function() calls$dispose <- calls$dispose + 1L
    )
  }

  sent <- list()
  shiny::testServer(function(input, output, session) {
    plugin <- .new_copilot_addin_plugin(
      auto_start = TRUE,
      persist_auto_start = function(value) persisted <<- c(persisted, value),
      service_factory = service_factory
    )
    session$userData$plugin <- plugin
    plugin$bind(session, "chat_input")
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()

    expect_identical(calls$start, 0L)
    expect_identical(session$userData$plugin$config(), list(
      version = 1L,
      state = list(status = "checking", autoStart = TRUE)
    ))

    session$setInputs(chat_input_copilot_service_ready = list(ts = 1))
    session$flushReact()
    expect_identical(calls$start, 1L)
    expect_identical(tail(sent, 1L)[[1L]]$type, "chat_input:copilot-service-status")
    expect_identical(tail(sent, 1L)[[1L]]$message$status, "starting")

    sent <- list()
    session$setInputs(chat_input_copilot_service_ready = list(ts = 2))
    session$flushReact()
    expect_identical(calls$start, 1L)
    expect_length(sent, 1L)
    expect_identical(sent[[1L]]$message$status, "starting")

    publish_from_service(list(status = "ready", autoStart = TRUE))
    expect_identical(tail(sent, 1L)[[1L]]$message$status, "ready")

    session$setInputs(chat_input_copilot_auto_start = list(value = FALSE, ts = 3))
    session$setInputs(chat_input_copilot_retry = list(ts = 4))
    session$flushReact()
    expect_identical(calls$auto, FALSE)
    expect_identical(persisted, FALSE)
    expect_identical(calls$retry, 1L)

    session$close()
    expect_identical(calls$dispose, 1L)
  })
})
