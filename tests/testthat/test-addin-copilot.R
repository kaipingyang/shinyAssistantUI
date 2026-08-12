new_fake_worker <- function(result = list(status = "ready", message = "ready")) {
  worker <- new.env(parent = emptyenv())
  worker$is_alive <- function() FALSE
  worker$get_result <- function() result
  worker
}

test_that("copilot service publishes checking, starting, then worker readiness", {
  events <- list()
  factory_calls <- 0L
  service <- .new_copilot_service(
    auto_start = TRUE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    worker_factory = function() {
      factory_calls <<- factory_calls + 1L
      new_fake_worker()
    },
    schedule = function(fn, delay) fn()
  )

  service$start()
  expect_identical(vapply(events, `[[`, character(1), "status"),
                   c("checking", "starting", "ready"))
  expect_identical(factory_calls, 1L)
  expect_true(all(vapply(events, `[[`, logical(1), "autoStart")))
})

test_that("disabled setting never launches and turning off does not terminate a worker", {
  events <- list()
  factory_calls <- 0L
  worker <- new_fake_worker(list(status = "failed", message = "not ready"))
  service <- .new_copilot_service(
    auto_start = FALSE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    worker_factory = function() {
      factory_calls <<- factory_calls + 1L
      worker
    },
    schedule = function(fn, delay) fn()
  )

  service$start()
  expect_identical(factory_calls, 0L)
  expect_identical(events[[1L]]$status, "disabled")

  service$set_auto_start(TRUE)
  expect_identical(factory_calls, 1L)
  service$set_auto_start(FALSE)
  expect_identical(tail(events, 1L)[[1L]]$status, "disabled")
  expect_identical(factory_calls, 1L)
})

test_that("retry is explicit and can recover a retained failed state", {
  events <- list()
  results <- list(
    list(status = "failed", message = "copilot-api did not become ready"),
    list(status = "ready", message = "copilot-api is ready")
  )
  calls <- 0L
  service <- .new_copilot_service(
    auto_start = TRUE,
    publish = function(value) events[[length(events) + 1L]] <<- value,
    worker_factory = function() {
      calls <<- calls + 1L
      new_fake_worker(results[[calls]])
    },
    schedule = function(fn, delay) fn()
  )

  service$start()
  expect_identical(tail(events, 1L)[[1L]]$status, "failed")
  service$retry()
  expect_identical(tail(events, 1L)[[1L]]$status, "ready")
  expect_identical(calls, 2L)
})


test_that("worker sequence health-checks before invoking the existing script", {
  events <- character()
  ready <- .copilot_api_start_sequence(
    script = "/existing/start.sh", timeout = 0, poll_interval = 0,
    health = function() { events <<- c(events, "health"); TRUE },
    launch = function(path) { events <<- c(events, paste0("launch:", path)); 0L },
    script_exists = function(path) TRUE,
    now = function() as.POSIXct("2026-01-01", tz = "UTC"),
    sleep = function(...) NULL
  )
  expect_identical(ready$status, "ready")
  expect_identical(events, "health")

  events <- character()
  checks <- 0L
  started <- .copilot_api_start_sequence(
    script = "/existing/start.sh", timeout = 1, poll_interval = 0,
    health = function() {
      checks <<- checks + 1L
      events <<- c(events, "health")
      checks >= 2L
    },
    launch = function(path) { events <<- c(events, paste0("launch:", path)); 0L },
    script_exists = function(path) TRUE,
    now = function() as.POSIXct("2026-01-01", tz = "UTC"),
    sleep = function(...) NULL
  )
  expect_identical(started$status, "ready")
  expect_identical(events, c("health", "launch:/existing/start.sh", "health"))
})


test_that("real callr worker accepts the serialized startup sequence", {
  missing_script <- tempfile("missing-copilot-script-")
  worker <- .copilot_api_worker(
    script = missing_script,
    url = "http://127.0.0.1:1/v1/models",
    timeout = 0,
    poll_interval = 0
  )
  on.exit(if (worker$is_alive()) worker$kill(), add = TRUE)
  worker$wait(timeout = 5000)
  result <- worker$get_result()
  expect_identical(result$status, "failed")
  expect_match(result$message, "Startup script not found", fixed = TRUE)
  expect_false(grepl("unused argument", result$message, fixed = TRUE))
})
