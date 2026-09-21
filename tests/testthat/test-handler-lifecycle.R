handler_lifecycle_result <- function(handler, on_done = function(...) NULL,
                                     on_chunk = function(...) invisible(NULL),
                                     is_cancelled = function() FALSE) {
  state <- new.env(parent = emptyenv())
  state$settled <- FALSE
  state$error <- NULL
  noop <- function(...) invisible(NULL)
  args <- list(
    message = "Synthetic lifecycle fixture", thread_id = "lifecycle-thread",
    attachments = list(), on_chunk = on_chunk, on_done = on_done, on_error = noop,
    on_tool_call = noop, on_tool_result = noop, on_thinking = noop,
    on_image = noop, on_artifact = noop, is_cancelled = is_cancelled,
    wait_for_approval = noop, register_cancel = noop
  )
  value <- tryCatch(
    do.call(handler, args[names(args) %in% names(formals(handler))]),
    error = identity
  )
  if (inherits(value, "condition")) {
    state$error <- value
    state$settled <- TRUE
  } else {
    promises::then(value, function(result) {
      state$settled <- TRUE
      NULL
    }, function(error) {
      state$error <- error
      state$settled <- TRUE
      NULL
    })
  }
  deadline <- Sys.time() + 5
  while (!state$settled) {
    later::run_now(0.01)
    if (Sys.time() > deadline) stop("Handler lifecycle fixture did not settle")
  }
  state
}

test_that("ellmer releases current callbacks after startup and terminal callback errors", {
  skip_if_not_installed("ellmer")
  for (fail_at in c("none", "stream", "done")) {
    captured <- new.env(parent = emptyenv())
    chat <- list(
      on_tool_request = function(callback) captured$request <- callback,
      on_tool_result = function(callback) captured$result <- callback,
      stream_async = function(...) {
        if (fail_at == "stream") stop("Synthetic stream startup failure")
        coro::async_generator(function() coro::yield("one chunk"))()
      }
    )
    handler <- make_ellmer_handler(function() chat)
    done <- function(...) {
      if (fail_at == "done") stop("Synthetic terminal callback failure")
    }
    result <- handler_lifecycle_result(handler, done)
    current <- get("current", environment(captured$result), inherits = FALSE)
    expect_identical(is.null(result$error), fail_at == "none")
    expect_null(current$on_tool_call)
    expect_null(current$on_tool_result)
    expect_null(current$wait_for_approval)
  }
})

test_that("ellmer waits for asynchronous iterator close after failure or cancellation", {
  skip_if_not_installed("ellmer")
  for (cause in c("error", "cancel")) {
    captured <- new.env(parent = emptyenv())
    closed <- cancelled <- FALSE
    close_count <- chunks <- 0L
    iterator <- function(close = FALSE) {
      if (close) {
        close_count <<- close_count + 1L
        return(promises::promise(function(resolve, reject) {
          later::later(function() {
            closed <<- TRUE
            resolve(NULL)
          }, 0.05)
        }))
      }
      promises::promise_resolve("partial text")
    }
    chat <- list(
      on_tool_request = function(callback) captured$request <- callback,
      on_tool_result = function(callback) captured$result <- callback,
      stream_async = function(...) iterator
    )
    handler <- make_ellmer_handler(function() chat)
    observed <- handler_lifecycle_result(
      handler, on_chunk = function(text) {
        chunks <<- chunks + 1L
        if (cause == "error") stop("Synthetic text callback failure")
        cancelled <<- TRUE
      },
      is_cancelled = function() cancelled
    )
    current <- get("current", environment(captured$result), inherits = FALSE)
    expect_null(observed$error)
    expect_true(closed)
    expect_identical(chunks, 1L)
    expect_identical(close_count, 1L)
    expect_null(current$on_tool_call)
    expect_null(current$on_tool_result)
    expect_null(current$wait_for_approval)
    deadline <- Sys.time() + 1
    while (!closed && Sys.time() < deadline) later::run_now(0.01)
  }
})

test_that("codeagent releases current callbacks and controller after terminal callback errors", {
  skip_if_not_installed("ellmer")
  for (fail_at in c("none", "done")) {
    captured <- new.env(parent = emptyenv())
    handler <- make_codeagent_handler(
      client_factory = function() list(chat = list()),
      gate_fn = function(chat, permission_mode, ask_fn, rules) captured$ask <- ask_fn,
      stream_fn = function(...) promises::promise_resolve(list(
        text = "Complete", stop_reason = "completed"
      ))
    )
    done <- function(...) {
      if (fail_at == "done") stop("Synthetic terminal callback failure")
    }
    result <- handler_lifecycle_result(handler, done)
    current <- get("current", environment(captured$ask), inherits = FALSE)
    expect_identical(is.null(result$error), fail_at == "none")
    for (field in c("on_tool_call", "on_tool_result", "wait_for_approval",
                    "project_tool_id", "project_tool_name", "controller")) {
      expect_null(current[[field]])
    }
    attr(handler, "teardown")()
  }
})

test_that("codeagent adapter coroutine only orchestrates the turn", {
  handler <- make_codeagent_handler(
    client_factory = function() list(),
    stream_fn = function(...) promises::promise_resolve(list(text = "Complete"))
  )
  on.exit(attr(handler, "teardown")(), add = TRUE)
  fn <- get("fn", environment(handler), inherits = FALSE)
  expect_lte(length(deparse(body(fn))), 100L)
})
