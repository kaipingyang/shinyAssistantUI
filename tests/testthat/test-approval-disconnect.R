test_that("a disconnected Manual approval retires the stale client and preserves resume", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  directory <- tempfile("approval-disconnect-")
  dir.create(directory)
  withr::defer(unlink(directory, recursive = TRUE, force = TRUE))
  session_map_path <- file.path(directory, "session-map.rds")
  saveRDS(list(`thread-a` = "session-existing"), session_map_path)

  created_options <- list()
  created_clients <- list()
  disconnect_calls <- integer(4L)

  make_client <- function(index) {
    connected <- TRUE
    queue <- if (index == 1L) {
      list(ClaudeAgentSDK::PermissionRequestMessage(
        request_id = "request-write",
        tool_name = "Write",
        tool_input = list(file_path = "test.txt", content = "test"),
        tool_use_id = "tool-write"
      ))
    } else {
      list(
        ClaudeAgentSDK::AssistantMessage(
          content = list(ClaudeAgentSDK::TextBlock("Resumed existing session.")),
          model = "mock-model",
          session_id = "session-existing"
        ),
        ClaudeAgentSDK::ResultMessage(
          subtype = "success",
          duration_ms = 1,
          duration_api_ms = 1,
          is_error = FALSE,
          num_turns = 1,
          session_id = "session-existing",
          result = "Resumed existing session."
        )
      )
    }
    client <- new.env(parent = emptyenv())
    client$connect <- function() {
      connected <<- TRUE
      invisible(NULL)
    }
    client$disconnect <- function() {
      disconnect_calls[[index]] <<- (disconnect_calls[[index]] %||% 0L) + 1L
      connected <<- FALSE
      invisible(NULL)
    }
    client$send <- function(...) {
      if (!connected) {
        ClaudeAgentSDK::claude_cli_connection_error(
          "Not connected. Call $connect() first."
        )
      }
      invisible(NULL)
    }
    client$poll_messages <- function() {
      if (!connected) {
        ClaudeAgentSDK::claude_cli_connection_error(
          "Not connected. Call $connect() first."
        )
      }
      value <- queue
      queue <<- list()
      value
    }
    client$get_server_info <- function() list()
    client$approve_tool <- function(...) {
      if (!connected) {
        ClaudeAgentSDK::claude_cli_connection_error(
          "Not connected. Call $connect() first."
        )
      }
      invisible(NULL)
    }
    client$deny_tool <- function(...) invisible(NULL)
    client$interrupt <- function(...) invisible(NULL)
    client
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) {
      index <- length(created_clients) + 1L
      created_options[[index]] <<- options
      client <- make_client(index)
      created_clients[[index]] <<- client
      client
    },
    .get_claude_session_messages = function(...) list(),
    .claude_idle_start_delay_seconds = function() 3600
  )

  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = session_map_path
  )
  withr::defer(attr(handler, "cleanup")())

  invoke <- function(message, disconnect_on_approval = FALSE) {
    state <- new.env(parent = emptyenv())
    state$done <- FALSE
    state$errors <- character()
    state$rejection <- NULL
    state$tool_results <- list()
    promise <- handler(
      message = message,
      thread_id = "thread-a",
      attachments = list(),
      on_chunk = function(...) NULL,
      on_done = function(...) state$done <- TRUE,
      on_error = function(error) state$errors <- c(state$errors, error),
      on_tool_call = function(...) NULL,
      on_tool_result = function(tool_call_id, result, is_error) {
        state$tool_results[[length(state$tool_results) + 1L]] <- list(
          id = tool_call_id,
          result = result,
          is_error = is_error
        )
      },
      on_thinking = function(...) NULL,
      is_cancelled = function() FALSE,
      wait_for_approval = function(...) {
        if (disconnect_on_approval) created_clients[[1L]]$disconnect()
        promises::promise_resolve(list(approved = TRUE))
      }
    )
    promises::then(
      promise,
      onFulfilled = function(value) state$settled <- TRUE,
      onRejected = function(error) {
        state$rejection <- conditionMessage(error)
        state$settled <- TRUE
      }
    )
    for (i in seq_len(500L)) {
      later::run_now(0.01)
      if (isTRUE(state$settled)) break
    }
    state
  }

  first <- invoke("write a synthetic test file", disconnect_on_approval = TRUE)
  expect_null(first$rejection)
  expect_match(first$errors, "connection closed while waiting for approval", ignore.case = TRUE)
  expect_false(any(grepl("Not connected", first$errors, fixed = TRUE)))
  expect_true(any(vapply(
    first$tool_results,
    function(item) isTRUE(item$is_error) && grepl("not run", item$result, ignore.case = TRUE),
    logical(1)
  )))
  decisions <- .read_tool_decisions(.claude_decisions_path(session_map_path))
  expect_null(decisions[["tool-write"]])

  second <- invoke("continue in the same synthetic session")
  expect_null(second$rejection)
  expect_true(second$done)
  expect_length(created_options, 2L)
  expect_identical(created_options[[2L]]$resume, "session-existing")
  expect_identical(.read_claude_session_map(session_map_path)[["thread-a"]],
                   "session-existing")
})
