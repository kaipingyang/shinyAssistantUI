test_that("make_claude_handler never finishes a terminal Claude result silently", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  run_turn <- function(messages, is_cancelled = function() FALSE) {
    queue <- messages
    client <- new.env(parent = emptyenv())
    client$connect <- function() invisible(NULL)
    client$disconnect <- function() invisible(NULL)
    client$send <- function(content) invisible(NULL)
    client$deny_tool <- function(...) invisible(NULL)
    client$approve_tool <- function(...) invisible(NULL)
    client$interrupt <- function(...) invisible(NULL)
    client$poll_messages <- function() {
      current <- queue
      queue <<- list()
      current
    }

    local_mocked_bindings(
      .new_claude_options = function(...) list(...),
      .new_claude_client = function(options) client,
      .claude_drain_timeout_seconds = function() 0.01
    )

    handler <- make_claude_handler(
      options = list(
        permission_mode = "default",
        permission_prompt_tool_name = "stdio",
        include_partial_messages = TRUE
      ),
      session_map_path = tempfile(fileext = ".rds")
    )
    captured <- new.env(parent = emptyenv())
    captured$chunks <- character()
    captured$done <- FALSE
    captured$error <- NULL
    captured$tool_starts <- character(0)
    captured$tool_results <- list()

    handler(
      message = "", thread_id = "image-thread",
      attachments = list(list(type = "image", data = "data:image/png;base64,AAAA")),
      on_chunk = function(text) captured$chunks <- c(captured$chunks, text),
      on_done = function(...) captured$done <- TRUE,
      on_error = function(message) captured$error <- message,
      on_tool_call = function(...) NULL,
      on_tool_result = function(tool_call_id, result, is_error) {
        captured$tool_results[[length(captured$tool_results) + 1L]] <- list(
          id = tool_call_id, result = result, is_error = is_error
        )
      },
      on_tool_call_start = function(tool_call_id, tool_name, annotations = list()) {
        captured$tool_starts <- c(captured$tool_starts, tool_call_id)
      },
      on_thinking = function(...) NULL,
      is_cancelled = is_cancelled,
      wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
    )

    for (i in seq_len(2000)) {
      later::run_now()
      if (isTRUE(captured$done) || !is.null(captured$error)) break
      Sys.sleep(0.002)
    }
    captured
  }

  result <- function(is_error = FALSE, text = NULL, api_error_status = NULL) {
    ClaudeAgentSDK::ResultMessage(
      subtype = if (is_error) "error_during_execution" else "success",
      duration_ms = 1, duration_api_ms = 1,
      is_error = is_error, num_turns = 1,
      session_id = "session-terminal-test",
      result = text, api_error_status = api_error_status
    )
  }
  assistant <- function(text) ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(text)),
    model = "mock-model", session_id = "session-terminal-test"
  )
  stream <- function(text) ClaudeAgentSDK::StreamEvent(
    uuid = "stream-event", session_id = "session-terminal-test",
    event = list(
      type = "content_block_delta", index = 0,
      delta = list(type = "text_delta", text = text)
    )
  )
  permission <- function() ClaudeAgentSDK::PermissionRequestMessage(
    request_id = "permission-request",
    tool_name = "Bash",
    tool_input = list(command = "echo test"),
    tool_use_id = "tool-use-terminal-test"
  )
  partial_tool_start <- function() ClaudeAgentSDK::StreamEvent(
    uuid = "partial-tool-event", session_id = "session-terminal-test",
    event = list(
      type = "content_block_start", index = 0,
      content_block = list(
        type = "tool_use", id = "partial-tool", name = "Bash"
      )
    )
  )

  from_assistant <- run_turn(list(
    assistant("I can see the image."),
    result(text = "I can see the image.")
  ))
  expect_identical(from_assistant$chunks, "I can see the image.")
  expect_true(from_assistant$done)
  expect_null(from_assistant$error)

  from_result <- run_turn(list(result(text = "Fallback from final result.")))
  expect_identical(from_result$chunks, "Fallback from final result.")
  expect_true(from_result$done)
  expect_null(from_result$error)

  streamed <- run_turn(list(
    stream("Already streamed."),
    assistant("Already streamed."),
    result(text = "Already streamed.")
  ))
  expect_identical(streamed$chunks, "Already streamed.")
  expect_true(streamed$done)
  expect_null(streamed$error)

  trailing_newline <- run_turn(list(
    assistant("Answer\n"),
    result(text = "Answer\n")
  ))
  expect_identical(trailing_newline$chunks, "Answer\n")
  expect_true(trailing_newline$done)
  expect_null(trailing_newline$error)

  streamed_whitespace <- run_turn(list(
    stream("Answer "),
    assistant("Answer "),
    result(text = "Answer ")
  ))
  expect_identical(streamed_whitespace$chunks, "Answer ")
  expect_true(streamed_whitespace$done)
  expect_null(streamed_whitespace$error)

  partial <- run_turn(list(
    stream("prefix "),
    assistant("prefix final answer"),
    result(text = "prefix final answer")
  ))
  expect_identical(partial$chunks, c("prefix ", "final answer"))
  expect_true(partial$done)
  expect_null(partial$error)

  assistant_shorter <- run_turn(list(
    assistant("prefix"),
    result(text = "prefix tail")
  ))
  expect_identical(assistant_shorter$chunks, c("prefix", " tail"))
  expect_true(assistant_shorter$done)
  expect_null(assistant_shorter$error)

  independent_round <- run_turn(list(
    stream("prefix SECOND suffix"),
    assistant("SECOND"),
    result(text = "SECOND")
  ))
  expect_identical(independent_round$chunks, c("prefix SECOND suffix", "SECOND"))
  expect_true(independent_round$done)
  expect_null(independent_round$error)

  multiple_assistants <- run_turn(list(
    assistant("First answer. "),
    assistant("Second answer."),
    result(text = "First answer. Second answer.")
  ))
  expect_identical(multiple_assistants$chunks, "First answer. Second answer.")
  expect_true(multiple_assistants$done)
  expect_null(multiple_assistants$error)

  denied <- run_turn(list(
    permission(),
    result(
      is_error = TRUE,
      text = "Interrupted by user.",
      api_error_status = "cancelled"
    )
  ))
  expect_true(denied$done)
  expect_null(denied$error)
  expect_length(denied$chunks, 0)

  denied_without_result <- run_turn(list(permission()))
  expect_true(denied_without_result$done)
  expect_null(denied_without_result$error)
  expect_length(denied_without_result$chunks, 0)

  cancel_checks <- 0L
  cancel_after_approval <- function() {
    cancel_checks <<- cancel_checks + 1L
    cancel_checks >= 2L
  }
  cancelled_approval <- run_turn(
    list(permission()),
    is_cancelled = cancel_after_approval
  )
  expect_true(cancelled_approval$done)
  expect_null(cancelled_approval$error)

  failed <- run_turn(list(result(
    is_error = TRUE,
    text = "Image input was rejected.",
    api_error_status = "invalid_request"
  )))
  expect_false(failed$done)
  expect_match(failed$error, "Image input was rejected", fixed = TRUE)

  failed_partial_tool <- run_turn(list(
    partial_tool_start(),
    result(is_error = TRUE, text = "Backend failed during tool input.")
  ))
  expect_identical(failed_partial_tool$tool_starts, "partial-tool")
  expect_length(failed_partial_tool$tool_results, 1L)
  expect_identical(failed_partial_tool$tool_results[[1L]]$id, "partial-tool")
  expect_true(failed_partial_tool$tool_results[[1L]]$is_error)
  expect_false(failed_partial_tool$done)
  expect_match(failed_partial_tool$error, "Backend failed", fixed = TRUE)

  expect_identical(.claude_terminal_suffix(character(), "terminal"), "terminal")
  expect_identical(.claude_terminal_suffix(NA_character_, "terminal"), "terminal")
  expect_identical(.claude_terminal_suffix("stream", NA_character_), "")
})
