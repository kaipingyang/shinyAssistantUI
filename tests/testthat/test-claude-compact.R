test_that("compact polling succeeds once on a structured ResultMessage", {
  queue <- list(
    list(structure(list(), class = "SystemMessage")),
    list(structure(list(session_id = "session-compact"), class = "ResultMessage"))
  )
  scheduled <- list()
  terminal <- list()
  persisted <- character()
  client <- new.env(parent = emptyenv())
  client$poll_messages <- function() {
    value <- queue[[1L]]
    queue <<- queue[-1L]
    value
  }

  shinyAssistantUI:::.claude_start_compact_poll(
    client = client,
    on_terminal = function(status, message) {
      terminal[[length(terminal) + 1L]] <<- list(status = status, message = message)
    },
    persist_result = function(msg) persisted <<- c(persisted, msg$session_id),
    timeout_seconds = 10,
    poll_interval = 0,
    schedule = function(callback, delay) scheduled[[length(scheduled) + 1L]] <<- callback
  )

  while (length(scheduled)) {
    callback <- scheduled[[1L]]
    scheduled <- scheduled[-1L]
    callback()
  }

  expect_length(terminal, 1L)
  expect_identical(terminal[[1L]]$status, "ok")
  expect_match(terminal[[1L]]$message, "compacted", ignore.case = TRUE)
  expect_identical(persisted, "session-compact")
})

test_that("compact polling reports poll failures immediately and only once", {
  scheduled <- list()
  terminal <- list()
  client <- new.env(parent = emptyenv())
  client$poll_messages <- function() stop("poll transport failed")

  shinyAssistantUI:::.claude_start_compact_poll(
    client = client,
    on_terminal = function(status, message) {
      terminal[[length(terminal) + 1L]] <<- list(status = status, message = message)
    },
    timeout_seconds = 10,
    poll_interval = 0,
    schedule = function(callback, delay) scheduled[[length(scheduled) + 1L]] <<- callback
  )

  callback <- scheduled[[1L]]
  callback()
  callback() # stale/re-entrant callback must not emit a second terminal result

  expect_length(terminal, 1L)
  expect_identical(terminal[[1L]]$status, "error")
  expect_match(terminal[[1L]]$message, "poll transport failed", fixed = TRUE)
})

test_that("compact polling uses a total wall clock despite continuous junk", {
  scheduled <- list()
  terminal <- list()
  clock <- 0
  polls <- 0L
  client <- new.env(parent = emptyenv())
  client$poll_messages <- function() {
    polls <<- polls + 1L
    clock <<- clock + 0.4
    list(structure(list(data = list(status = "compacting")), class = "SystemMessage"))
  }

  shinyAssistantUI:::.claude_start_compact_poll(
    client = client,
    on_terminal = function(status, message) {
      terminal[[length(terminal) + 1L]] <<- list(status = status, message = message)
    },
    timeout_seconds = 1,
    poll_interval = 0,
    now = function() clock,
    schedule = function(callback, delay) scheduled[[length(scheduled) + 1L]] <<- callback
  )

  while (length(scheduled) && length(terminal) == 0L) {
    callback <- scheduled[[1L]]
    scheduled <- scheduled[-1L]
    callback()
  }

  expect_gte(polls, 2L)
  expect_length(terminal, 1L)
  expect_identical(terminal[[1L]]$status, "error")
  expect_match(terminal[[1L]]$message, "timed out", ignore.case = TRUE)
})


test_that("compact action never creates a second consumer for an active turn", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  sent <- character()
  cancelled <- FALSE
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(content) sent <<- c(sent, as.character(content))
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() list()
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_drain_timeout_seconds = function() 0
  )

  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  finished <- FALSE
  handler(
    message = "active", thread_id = "shared-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) finished <<- TRUE,
    on_error = function(...) finished <<- TRUE,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() cancelled,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  later::run_now()

  action_results <- list()
  attr(handler, "action_handler")(
    "compact", "shared-thread",
    function(message, status = "ok", value = NULL) {
      action_results[[length(action_results) + 1L]] <<- list(
        status = status, message = message
      )
    }
  )
  expect_length(action_results, 1L)
  expect_identical(action_results[[1L]]$status, "error")
  expect_match(action_results[[1L]]$message, "response is running", fixed = TRUE)
  expect_false("/compact" %in% sent)

  cancelled <- TRUE
  for (i in seq_len(200L)) {
    later::run_now()
    if (finished) break
    Sys.sleep(0.002)
  }
  expect_true(finished)
})

test_that("a second compact action is rejected without disturbing the first", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  result <- function() ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "compact-lock-session"
  )
  queue <- list(result())
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(content) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    value <- queue
    queue <<- list()
    value
  }
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_compact_timeout_seconds = function() 10
  )

  handler <- make_claude_handler(
    options = list(permission_mode = "default", include_partial_messages = TRUE),
    session_map_path = tempfile(fileext = ".rds")
  )
  turn_done <- FALSE
  handler(
    message = "ready", thread_id = "compact-lock-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) turn_done <<- TRUE,
    on_error = function(...) turn_done <<- TRUE,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  for (i in seq_len(20L)) {
    later::run_now()
    if (turn_done) break
    Sys.sleep(0.001)
  }
  expect_true(turn_done)

  first <- list()
  second <- list()
  action <- attr(handler, "action_handler")
  action("compact", "compact-lock-thread", function(message, status = "ok", value = NULL) {
    first[[length(first) + 1L]] <<- list(status = status, message = message)
  })
  action("compact", "compact-lock-thread", function(message, status = "ok", value = NULL) {
    second[[length(second) + 1L]] <<- list(status = status, message = message)
  })
  expect_identical(first[[1L]]$status, "progress")
  expect_length(second, 1L)
  expect_identical(second[[1L]]$status, "error")
  expect_match(second[[1L]]$message, "already running", fixed = TRUE)


  blocked_error <- NULL
  handler(
    message = "must wait", thread_id = "compact-lock-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) NULL,
    on_error = function(message) blocked_error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  for (i in seq_len(20L)) {
    later::run_now()
    if (!is.null(blocked_error)) break
    Sys.sleep(0.001)
  }
  expect_match(blocked_error, "compaction is still running", fixed = TRUE)
  queue <- list(result())
  for (i in seq_len(400L)) {
    later::run_now()
    if (length(first) > 1L) break
    Sys.sleep(0.002)
  }
  expect_length(first, 2L)
  expect_identical(first[[2L]]$status, "ok")

  queue <- list(result())
  resumed_done <- FALSE
  handler(
    message = "after compact", thread_id = "compact-lock-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) resumed_done <<- TRUE,
    on_error = function(...) NULL,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  for (i in seq_len(50L)) {
    later::run_now()
    if (resumed_done) break
    Sys.sleep(0.001)
  }
  expect_true(resumed_done)
})
