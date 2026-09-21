drain_connection_callbacks <- function(predicate, seconds = 0.5) {
  deadline <- Sys.time() + seconds
  while (!isTRUE(predicate()) && Sys.time() < deadline) {
    later::run_now(0.01)
    Sys.sleep(0.005)
  }
  isTRUE(predicate())
}

test_that("registered asynchronous clients do not call blocking connect and remain cancellable", {
  registered <- NULL
  ready <- failed <- NULL
  closed <- FALSE
  client <- new.env(parent = emptyenv())
  client$connect <- function() stop("Blocking connect must not run")
  client$disconnect <- function() closed <<- TRUE
  client$connect_async <- function(on_fulfilled, on_rejected) {
    ready <<- on_fulfilled
    failed <<- on_rejected
    function() {
      reason <- simpleError("Initialization cancelled")
      class(reason) <- c("claude_connection_cancelled", class(reason))
      on_rejected(reason)
      TRUE
    }
  }
  result <- .connect_registered_claude_client(
    client, register = function(value) registered <<- value,
    unregister = function(value) registered <<- NULL, async = TRUE
  )
  expect_identical(registered, client)
  expect_s3_class(result, "promise")
  expect_true(is.function(attr(result, "cancel")))
  observed <- NULL
  promises::then(result, onRejected = function(error) observed <<- error)
  expect_true(attr(result, "cancel")())
  expect_true(drain_connection_callbacks(function() !is.null(observed)))
  expect_s3_class(observed, "claude_connection_cancelled")
  expect_null(registered)
  expect_true(closed)
})

test_that("asynchronous resume failure falls back exactly once before any prompt", {
  fallbacks <- notices <- 0L
  result <- .claude_connect_with_resume_policy(
    stored_sid = "saved",
    connect_resume = function(sid) promises::promise(function(resolve, reject) {
      later::later(function() reject(simpleError("Missing old session")), 0.01)
    }),
    connect_fresh = function() {
      fallbacks <<- fallbacks + 1L
      "fresh"
    },
    on_normal_resume_failure = function(error) notices <<- notices + 1L
  )
  value <- reason <- NULL
  promises::then(result, function(x) value <<- x, function(error) reason <<- error)
  expect_true(drain_connection_callbacks(function() !is.null(value) || !is.null(reason)))
  expect_null(reason)
  expect_identical(value, "fresh")
  expect_identical(fallbacks, 1L)
  expect_identical(notices, 1L)
})

test_that("cancelled and strict asynchronous resumes never create fresh sessions", {
  for (strict in c(FALSE, TRUE)) {
    fresh <- 0L
    reason <- simpleError("Initialization cancelled")
    class(reason) <- c("claude_connection_cancelled", class(reason))
    result <- .claude_connect_with_resume_policy(
      stored_sid = "saved",
      strict_sid = if (strict) "strict" else NULL,
      connect_resume = function(sid) promises::promise(function(resolve, reject) {
        later::later(function() reject(reason), 0.01)
      }),
      connect_fresh = function() {
        fresh <<- fresh + 1L
        "fresh"
      }
    )
    observed <- NULL
    promises::then(result, onRejected = function(error) observed <<- error)
    expect_true(drain_connection_callbacks(function() !is.null(observed)))
    expect_identical(fresh, 0L)
    expect_s3_class(observed, "claude_connection_cancelled")
  }
})

test_that("Cancel after a resume rejection still prevents its pending fresh fallback", {
  cancelled <- FALSE
  reject_resume <- NULL
  fallbacks <- notices <- 0L
  result <- .claude_connect_with_resume_policy(
    stored_sid = "saved",
    connect_resume = function(sid) promises::promise(function(resolve, reject) {
      reject_resume <<- reject
    }),
    connect_fresh = function() { fallbacks <<- fallbacks + 1L; "fresh" },
    on_normal_resume_failure = function(error) notices <<- notices + 1L,
    is_cancelled = function() cancelled
  )
  observed <- NULL
  promises::then(result, onRejected = function(error) observed <<- error)
  reject_resume(simpleError("Resume refused"))
  cancelled <- TRUE
  expect_true(drain_connection_callbacks(function() !is.null(observed)))
  expect_s3_class(observed, "claude_connection_cancelled")
  expect_identical(fallbacks, 0L)
  expect_identical(notices, 0L)
})

test_that("cleanup cancels a replacement connection even with an old retired consumer", {
  created <- list()
  new_ready <- NULL
  aborts <- sends <- 0L
  factory <- function(options) {
    index <- length(created) + 1L
    client <- new.env(parent = emptyenv())
    client$alive <- FALSE
    client$connect <- function() client$alive <- TRUE
    client$is_alive <- function() client$alive
    client$disconnect <- function() client$alive <- FALSE
    client$poll_messages <- function() list()
    client$interrupt <- function() invisible(NULL)
    client$get_server_info <- function() list()
    client$send <- function(...) sends <<- sends + 1L
    if (index > 1L) {
      client$connect_async <- function(on_fulfilled, on_rejected) {
        client$alive <- TRUE
        new_ready <<- function() on_fulfilled(client)
        function() {
          aborts <<- aborts + 1L
          client$alive <- FALSE
          reason <- simpleError("Initialization cancelled")
          class(reason) <- c("claude_connection_cancelled", class(reason))
          on_rejected(reason)
          TRUE
        }
      }
    }
    created[[index]] <<- client
    client
  }
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = factory,
    .claude_idle_start_delay_seconds = function() 3600
  )
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  withr::defer(attr(handler, "cleanup")())
  attr(handler, "warmup")("history")
  expect_length(created, 1L)
  created[[1L]]$alive <- FALSE
  result <- handler(
    message = "retry", thread_id = "history", attachments = list(),
    on_chunk = function(...) NULL, on_done = function(...) NULL,
    on_error = function(...) NULL, on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL, on_thinking = function(...) NULL,
    is_cancelled = function() FALSE, wait_for_approval = function(...) NULL
  )
  settled <- FALSE
  promises::then(result, function(value) settled <<- TRUE, function(error) settled <<- TRUE)
  expect_true(drain_connection_callbacks(function() !is.null(new_ready)))
  expect_length(created, 2L)
  attr(handler, "cleanup")()
  expect_identical(aborts, 1L)
  expect_false(created[[2L]]$alive)
  new_ready()
  expect_true(drain_connection_callbacks(function() settled, 2))
  expect_identical(sends, 0L)
  expect_identical(attr(handler, "performance_snapshot")()$coordinators, 0L)
})
