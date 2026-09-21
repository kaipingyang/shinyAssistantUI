test_that("the foreground coroutine contains orchestration rather than message parsing", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  on.exit(attr(handler, "cleanup")(), add = TRUE)
  coroutine <- get("fn", envir = environment(handler), inherits = FALSE)
  expect_lte(length(deparse(body(coroutine))), 160L)
})

test_that("foreground batches yield at the message budget", {
  count <- 0L
  status <- shinyAssistantUI:::.claude_foreground_batch(
    step = function() {
      count <<- count + 1L
      "continue"
    },
    now = function() 0
  )
  expect_identical(status, "yield")
  expect_identical(count, 32L)
})

test_that("foreground batches yield at the time budget even before the count budget", {
  count <- 0L
  clock <- -0.003
  status <- shinyAssistantUI:::.claude_foreground_batch(
    step = function() {
      count <<- count + 1L
      "continue"
    },
    now = function() {
      clock <<- clock + 0.003
      clock
    }
  )
  expect_identical(status, "yield")
  expect_identical(count, 3L)
})

test_that("foreground batches stop immediately at idle, approval, and terminal boundaries", {
  for (boundary in c("idle", "approval", "done")) {
    count <- 0L
    status <- shinyAssistantUI:::.claude_foreground_batch(
      step = function() {
        count <<- count + 1L
        if (count == 2L) return(boundary)
        "continue"
      },
      now = function() 0
    )
    expect_identical(status, boundary)
    expect_identical(count, 2L)
  }
  expect_error(
    shinyAssistantUI:::.claude_foreground_batch(
      function() "unknown", now = function() 0
    ),
    "Unexpected foreground step status"
  )
})

plan138_stream <- function(text) {
  ClaudeAgentSDK::StreamEvent(
    uuid = "batch-stream", session_id = "batch-session",
    event = list(
      type = "content_block_delta", index = 0L,
      delta = list(type = "text_delta", text = text)
    )
  )
}

plan138_result <- function() {
  ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "batch-session"
  )
}

plan138_fixture <- function(messages, .env = parent.frame()) {
  state <- new.env(parent = emptyenv())
  state$queue <- messages
  state$chunks <- character()
  state$tools <- list()
  state$done <- 0L
  state$errors <- character()
  state$approved <- character()
  state$denied <- character()
  state$interrupts <- 0L
  state$connections <- state$disconnects <- 0L
  state$settled <- FALSE
  state$rejection <- NULL
  state$decision <- NULL
  state$cancelled <- FALSE
  state$order <- character()
  loop <- later::global_loop()

  client <- new.env(parent = emptyenv())
  client$connect <- function() state$connections <- state$connections + 1L
  client$disconnect <- function() state$disconnects <- state$disconnects + 1L
  client$send <- function(content) invisible(NULL)
  client$poll_messages <- function() {
    batch <- state$queue
    state$queue <- list()
    batch
  }
  client$interrupt <- function() {
    state$interrupts <- state$interrupts + 1L
    invisible(NULL)
  }
  client$approve_tool <- function(request_id, ...) {
    state$approved <- c(state$approved, request_id)
    state$order <- c(state$order, "approved")
    invisible(NULL)
  }
  client$deny_tool <- function(request_id, ...) {
    state$denied <- c(state$denied, request_id)
    invisible(NULL)
  }
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) {
      list2env(as.list(client, all.names = TRUE), parent = emptyenv())
    },
    .package = "shinyAssistantUI", .env = .env
  )
  handler <- make_claude_handler(
    session_map_path = tempfile(fileext = ".rds")
  )
  withr::defer({
    attr(handler, "cleanup")()
  }, envir = .env)
  start <- function(overrides = list()) {
    state$settled <- FALSE
    state$rejection <- NULL
    args <- utils::modifyList(list(
      message = "A deterministic batch", thread_id = "batch-thread",
      attachments = list(),
      on_chunk = function(text) {
        state$chunks <- c(state$chunks, text)
        state$order <- c(state$order, text)
      },
      on_done = function() state$done <- state$done + 1L,
      on_error = function(message) state$errors <- c(state$errors, message),
      on_tool_call = function(...) state$tools <- c(state$tools, list(list(...))),
      on_tool_result = function(...) invisible(NULL),
      on_thinking = function(...) invisible(NULL),
      is_cancelled = function() state$cancelled,
      wait_for_approval = function(...) promises::promise(function(resolve, reject) {
        state$decision <- resolve
      })
    ), overrides)
    later::with_loop(loop, {
      promise <- do.call(handler, args)
      promises::then(promise, function(value) {
        state$settled <- TRUE
        value
      }, function(error) {
        state$rejection <- error
        state$settled <- TRUE
        NULL
      })
    })
    invisible(NULL)
  }
  drive <- function(until = function() state$settled) {
    deadline <- proc.time()[["elapsed"]] + 10
    while (!isTRUE(until())) {
      later::run_now(0.005, all = FALSE, loop = loop)
      if (proc.time()[["elapsed"]] > deadline) {
        stop("Foreground batch fixture did not settle")
      }
    }
    invisible(NULL)
  }
  list(state = state, handler = handler, start = start, drive = drive, loop = loop)
}

test_that("production foreground yields to cancellation before draining a queued response", {
  skip_if_not_installed("ClaudeAgentSDK")
  chunks <- sprintf("fragment %03d ", seq_len(128L))
  fixture <- plan138_fixture(c(lapply(chunks, plan138_stream), list(plan138_result())))
  state <- fixture$state
  delivered_at_yield <- NULL
  fixture$start(list(on_chunk = function(text) {
    state$chunks <- c(state$chunks, text)
    if (length(state$chunks) == 1L) {
      later::later(function() {
        delivered_at_yield <<- length(state$chunks)
        state$cancelled <- TRUE
      }, 0)
    }
  }))
  fixture$drive()
  expect_null(state$rejection)
  expect_length(state$errors, 0L)
  expect_identical(state$done, 1L)
  expect_identical(state$interrupts, 1L)
  expect_gte(delivered_at_yield, 1L)
  expect_lte(delivered_at_yield, 32L)
  expect_identical(state$chunks, chunks[seq_len(delivered_at_yield)])
})

test_that("production foreground pauses a buffered batch at permission until its decision", {
  skip_if_not_installed("ClaudeAgentSDK")
  permission <- ClaudeAgentSDK::PermissionRequestMessage(
    request_id = "batch-request", tool_name = "Bash",
    tool_input = list(command = "echo batch"), tool_use_id = "batch-tool"
  )
  fixture <- plan138_fixture(list(
    plan138_stream("before "), permission,
    plan138_stream("after "), plan138_result(),
    plan138_stream("must remain after Result ")
  ))
  state <- fixture$state
  fixture$start()
  fixture$drive(function() is.function(state$decision))
  expect_identical(state$chunks, "before ")
  expect_identical(state$done, 0L)
  expect_length(state$tools, 1L)
  expect_identical(state$tools[[1L]]$tool_call_id, "batch-tool")
  expect_length(state$approved, 0L)

  later::with_loop(fixture$loop, state$decision(list(approved = TRUE)))
  fixture$drive()
  expect_null(state$rejection)
  expect_length(state$errors, 0L)
  expect_identical(state$approved, "batch-request")
  expect_identical(state$order, c("before ", "approved", "after "))
  expect_identical(state$chunks, c("before ", "after "))
  expect_identical(state$done, 1L)
  snapshot <- attr(fixture$handler, "performance_snapshot")()
  expect_identical(snapshot$active_turns, 0L)
})

test_that("a rejected foreground callback reports failure and retires before the next turn", {
  skip_if_not_installed("ClaudeAgentSDK")
  fixture <- plan138_fixture(list(plan138_stream("fails ")))
  state <- fixture$state
  fixture$start(list(on_chunk = function(text) stop("batch callback rejected")))
  fixture$drive()
  expect_null(state$rejection)
  expect_identical(state$errors, "batch callback rejected")
  expect_identical(state$done, 0L)
  expect_identical(state$disconnects, 1L)
  expect_identical(attr(fixture$handler, "performance_snapshot")()$active_turns, 0L)
  expect_identical(attr(fixture$handler, "performance_snapshot")()$connected_clients, 0L)

  state$queue <- list(plan138_stream("recovered "), plan138_result())
  fixture$start()
  fixture$drive()
  expect_null(state$rejection)
  expect_identical(state$errors, "batch callback rejected")
  expect_identical(state$connections, 2L)
  expect_identical(state$chunks, "recovered ")
  expect_identical(state$done, 1L)
})
