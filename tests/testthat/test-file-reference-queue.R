file_reference_scheduler <- function() {
  timers <- list()
  schedule <- function(callback, delay) {
    timer <- new.env(parent = emptyenv())
    timer$active <- TRUE
    timer$callback <- callback
    timer$delay <- delay
    timers[[length(timers) + 1L]] <<- timer
    function() { timer$active <- FALSE; invisible(TRUE) }
  }
  list(
    schedule = schedule,
    pending = function() Filter(function(timer) timer$active, timers),
    all = function() timers,
    run = function() {
      active <- Filter(function(timer) timer$active, timers)
      stopifnot(length(active) == 1L)
      active[[1L]]$active <- FALSE
      active[[1L]]$callback()
    }
  )
}

test_that("file confirmation slices bound both count and elapsed work with one timer", {
  for (duration in c(0, 0.02)) {
    scheduler <- file_reference_scheduler()
    clock <- 0
    calls <- character()
    replies <- list()
    queue <- .new_file_reference_queue(
      resolve = function(path, request) {
        calls <<- c(calls, path)
        clock <<- clock + duration
        paste0("/project/", path)
      },
      deliver = function(request, files) replies[[request$requestId]] <<- files,
      schedule = scheduler$schedule,
      now = function() clock
    )
    queue$submit(list(requestId = "one", paths = as.list(paste0(seq_len(8L), ".R"))))
    expect_length(calls, 0L)
    expect_length(scheduler$pending(), 1L)
    scheduler$run()
    expect_length(calls, if (duration == 0) 4L else 1L)
    expect_length(replies, 0L)
    expect_length(scheduler$pending(), 1L)
    expect_gt(scheduler$pending()[[1L]]$delay, 0)
    while (length(scheduler$pending())) scheduler$run()
    expect_length(calls, 8L)
    expect_length(replies$one, 8L)
    expect_identical(replies$one[[1L]], list(path = "1.R", resolvedPath = "/project/1.R"))
    queue$close()
  }
})

test_that("new requests and close invalidate queued callbacks without delivering stale files", {
  scheduler <- file_reference_scheduler()
  calls <- character()
  replies <- character()
  queue <- .new_file_reference_queue(
    resolve = function(path, request) { calls <<- c(calls, path); NULL },
    deliver = function(request, files) replies <<- c(replies, request$requestId),
    schedule = scheduler$schedule
  )
  queue$submit(list(requestId = "old", paths = list("old.R")))
  stale <- scheduler$all()[[1L]]$callback
  queue$submit(list(requestId = "new", paths = list("new.R")))
  stale()
  expect_length(calls, 0L)
  expect_length(scheduler$pending(), 1L)
  scheduler$run()
  expect_identical(calls, "new.R")
  expect_identical(replies, "new")
  queue$submit(list(requestId = "closing", paths = list("closing.R")))
  closing <- tail(scheduler$all(), 1L)[[1L]]$callback
  queue$close()
  closing()
  expect_length(scheduler$pending(), 0L)
  expect_identical(calls, "new.R")
  expect_false(queue$submit(list(requestId = "closed", paths = list("never.R"))))
})

test_that("resolver failures are reported and preserve exact null response slots", {
  scheduler <- file_reference_scheduler()
  failures <- character()
  files <- NULL
  queue <- .new_file_reference_queue(
    resolve = function(path, request) stop("Synthetic resolver failure"),
    deliver = function(request, resolved) files <<- resolved,
    on_error = function(error) failures <<- c(failures, conditionMessage(error)),
    schedule = scheduler$schedule
  )
  queue$submit(list(requestId = "failure", paths = list("bad.R")))
  scheduler$run()
  expect_identical(failures, "Synthetic resolver failure")
  expect_identical(files, list(list(path = "bad.R", resolvedPath = NULL)))
  expect_length(scheduler$pending(), 0L)
})
