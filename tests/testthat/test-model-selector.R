# Model changes follow the official SDK contract: correlated acknowledgement
# first, then commit the selected model for future reconnects.

test_that("model action commits only after async acknowledgement", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  sync_calls <- character()
  pending <- NULL
  results <- list()
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$set_model <- function(model) sync_calls <<- c(sync_calls, model)
  client$set_model_async <- function(model, timeout_ms = 5000L,
                                     on_fulfilled = NULL, on_rejected = NULL) {
    pending <<- list(
      model = model, timeout_ms = timeout_ms,
      resolve = on_fulfilled, reject = on_rejected
    )
    invisible("model-request")
  }
  testthat::local_mocked_bindings(
    .new_claude_client = function(options) { received <<- options; client }
  )

  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  cap <- attr(handler, "ui_capabilities")$model
  expect_identical(cap$value, "default")
  expect_true(all(c("default", "haiku", "sonnet", "opus") %in%
                    vapply(cap$options, `[[`, character(1), "value")))

  attr(handler, "warmup")("t1")
  expect_null(received$model)
  attr(handler, "action_handler")(
    "model:sonnet", "t1",
    function(message, status = "ok", value = NULL) {
      results[[length(results) + 1L]] <<- list(status = status, value = value)
    }
  )

  expect_length(sync_calls, 0L)
  expect_identical(pending$model, "sonnet")
  # A healthy first CLI acknowledgement can arrive just beyond the SDK's
  # legacy five-second default on a cold or loaded backend.
  expect_identical(pending$timeout_ms, 30000L)
  expect_false(any(vapply(results, function(item) identical(item$status, "ok"), logical(1))))

  pending$resolve(list())
  expect_identical(results[[length(results)]]$status, "ok")
  expect_identical(results[[length(results)]]$value, "sonnet")

  attr(handler, "reset_clients")()
  attr(handler, "warmup")("t1")
  expect_identical(received$model, "sonnet")

  res2 <- NULL
  attr(handler, "action_handler")("model:bogus", "t1",
    function(message, status = "ok", value = NULL) res2 <<- status)
  expect_identical(res2, "error")
})


test_that("model action rejection preserves the previous model", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  reject_model <- NULL
  results <- list()
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$set_model <- function(model) stop("fire-and-forget path must not be used")
  client$set_model_async <- function(model, timeout_ms = 5000L,
                                     on_fulfilled = NULL, on_rejected = NULL) {
    reject_model <<- on_rejected
    invisible("model-request")
  }
  testthat::local_mocked_bindings(
    .new_claude_client = function(options) { received <<- options; client }
  )
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  attr(handler, "action_handler")(
    "model:sonnet", "t1",
    function(message, status = "ok", value = NULL) {
      results[[length(results) + 1L]] <<- list(message = message, status = status)
    }
  )
  reject_model(simpleError("model switch rejected"))

  expect_identical(results[[length(results)]]$status, "error")
  expect_match(results[[length(results)]]$message, "model switch rejected", fixed = TRUE)
  attr(handler, "reset_clients")()
  attr(handler, "warmup")("t1")
  expect_null(received$model)
})




test_that("model actions and committed state are isolated by thread", {
  skip_if_not_installed("ClaudeAgentSDK")
  requests <- list()
  results <- list()
  connects <- 0L
  created_options <- list()
  queue <- list()
  done <- FALSE
  foreground_error <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$approve_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$get_server_info <- function() list(commands = list(), output_styles = list())
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }
  client$send <- function(content) {
    queue <<- list(structure(list(
      subtype = "success", duration_ms = 1, duration_api_ms = 1,
      is_error = FALSE, num_turns = 1L, session_id = "cold-model-session",
      result = "Done.", stop_reason = "end_turn", usage = list(input_tokens = 1L)
    ), class = "ResultMessage"))
    invisible(NULL)
  }
  client$set_model_async <- function(model, timeout_ms = 5000L,
                                     on_fulfilled = NULL, on_rejected = NULL) {
    requests[[length(requests) + 1L]] <<- list(
      model = model, resolve = on_fulfilled, reject = on_rejected
    )
    invisible("model-request")
  }
  testthat::local_mocked_bindings(.new_claude_client = function(options) {
    connects <<- connects + 1L
    created_options[[connects]] <<- options
    client
  })
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  result <- function(thread) function(message, status = "ok", value = NULL) {
    results[[length(results) + 1L]] <<- list(thread = thread, status = status, message = message)
  }

  attr(handler, "action_handler")("model:sonnet", "t1", result("t1"))
  attr(handler, "action_handler")("model:opus", "t2", result("t2"))

  expect_length(requests, 2L)
  expect_identical(connects, 2L)
  expect_identical(vapply(requests, `[[`, character(1), "model"), c("sonnet", "opus"))

  attr(handler, "action_handler")("model:haiku", "t1", result("t1-overlap"))
  expect_length(requests, 2L)
  expect_identical(results[[length(results)]]$thread, "t1-overlap")
  expect_identical(results[[length(results)]]$status, "error")
  expect_match(results[[length(results)]]$message, "already in progress", ignore.case = TRUE)

  requests[[2L]]$resolve(list())
  requests[[1L]]$resolve(list())
  expect_true(any(vapply(results, function(item) {
    identical(item$thread, "t1") && identical(item$status, "ok")
  }, logical(1))))
  expect_true(any(vapply(results, function(item) {
    identical(item$thread, "t2") && identical(item$status, "ok")
  }, logical(1))))

  attr(handler, "reset_clients")()
  attr(handler, "warmup")("t1")
  attr(handler, "warmup")("t2")
  expect_identical(connects, 4L)
  expect_identical(created_options[[3L]]$model, "sonnet")
  expect_identical(created_options[[4L]]$model, "opus")
})
test_that("foreground send waits asynchronously for the pending model acknowledgement", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  withr::local_options(shinyAssistantUI.claude_idle_start_delay = 0)
  queue <- list()
  sends <- 0L
  model_pending <- NULL
  stage_trace <- character()
  done <- FALSE
  error <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$approve_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$get_server_info <- function() list(commands = list(), output_styles = list())
  client$set_model <- function(model) invisible(NULL)
  client$set_model_async <- function(model, timeout_ms = 5000L,
                                     on_fulfilled = NULL, on_rejected = NULL) {
    model_pending <<- list(resolve = on_fulfilled, reject = on_rejected)
    queue <<- c(queue, list(structure(
      list(content = "control replay", is_replay = TRUE),
      class = c("UserMessage", "list")
    )))
    invisible("model-request")
  }
  client$send <- function(content) {
    sends <<- sends + 1L
    queue <<- list(structure(list(
      subtype = "success", duration_ms = 1, duration_api_ms = 1,
      is_error = FALSE, num_turns = 1L, session_id = "model-session",
      result = "Done.", stop_reason = "end_turn", usage = list(input_tokens = 1L)
    ), class = "ResultMessage"))
    invisible(NULL)
  }
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }
  testthat::local_mocked_bindings(.new_claude_client = function(options) client)
  handler <- make_claude_handler(
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("t1")
  attr(handler, "action_handler")("model:sonnet", "t1", function(...) NULL)

  handler(
    message = "next", thread_id = "t1", attachments = list(),
    on_chunk = function(...) stage_trace <<- c(stage_trace, "streaming-callback"),
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    on_run_phase = function(stage) stage_trace <<- c(stage_trace, stage),
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  later::run_now(0.05)

  expect_identical(sends, 0L)
  expect_false(done)
  expect_true(is.function(model_pending$resolve))

  model_pending$resolve(list())
  attr(handler, "action_handler")("model:haiku", "t1", function(...) NULL)
  later::run_now(0.05)
  expect_identical(sends, 0L)
  expect_false(done)

  model_pending$resolve(list())
  for (i in seq_len(100L)) {
    later::run_now(0.01)
    if (done || !is.null(error)) break
  }
  expect_null(error)
  expect_identical(sends, 1L)
  expect_true(done)
  expected_stages <- c(
    "model-switch", "consumer-acquire", "sending", "awaiting-model", "finalizing"
  )
  stage_positions <- match(expected_stages, stage_trace)
  expect_false(anyNA(stage_positions))
  expect_identical(stage_positions, sort(stage_positions))
  expect_lt(match("streaming-callback", stage_trace), match("finalizing", stage_trace))
  later::run_now(0.05)

  done <- FALSE
  error <- NULL
  attr(handler, "action_handler")("model:opus", "t1", function(...) NULL)
  handler(
    message = "after rejection", thread_id = "t1", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  later::run_now(0.05)
  expect_identical(sends, 1L)

  model_pending$reject(simpleError("model switch rejected"))
  for (i in seq_len(100L)) {
    later::run_now(0.01)
    if (done || !is.null(error)) break
  }
  expect_null(error)
  expect_identical(sends, 2L)
  expect_true(done)

  done <- FALSE
  cancelled <- FALSE
  attr(handler, "action_handler")("model:haiku", "t1", function(...) NULL)
  handler(
    message = "cancel before send", thread_id = "t1", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() cancelled,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  later::run_now(0.02)
  cancelled <- TRUE
  model_pending$resolve(list())
  for (i in seq_len(100L)) {
    later::run_now(0.01)
    if (done || !is.null(error)) break
  }
  expect_null(error)
  expect_true(done)
  expect_identical(sends, 2L)
})

test_that("models= 覆盖档位、default 恒在首位、按传入顺序", {
  skip_if_not_installed("ClaudeAgentSDK")
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL); client$disconnect <- function() invisible(NULL)
  testthat::local_mocked_bindings(.new_claude_client = function(options) client)
  handler <- make_claude_handler(
    models = c("gpt-4o", "claude-x"),
    options = list(permission_mode = "default", permission_prompt_tool_name = "stdio",
                   include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  vals <- vapply(attr(handler, "ui_capabilities")$model$options, `[[`, character(1), "value")
  expect_identical(vals, c("default", "gpt-4o", "claude-x"))
})
