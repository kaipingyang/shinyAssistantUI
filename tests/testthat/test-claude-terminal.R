test_that("make_claude_handler never finishes a terminal Claude result silently", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  run_turn <- function(messages, is_cancelled = function() FALSE, message = "") {
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
    captured$auto_continue <- list()
    captured$tool_starts <- character(0)
    captured$tool_results <- list()

    handler(
      message = message, thread_id = "image-thread",
      attachments = list(list(type = "image", data = "data:image/png;base64,AAAA")),
      on_chunk = function(text) captured$chunks <- c(captured$chunks, text),
      on_done = function(...) captured$done <- TRUE,
      on_error = function(message) captured$error <- message,
      on_auto_continue = function(notice, prompt) {
        captured$auto_continue[[length(captured$auto_continue) + 1L]] <- list(
          notice = notice, prompt = prompt
        )
      },
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

  result <- function(is_error = FALSE, text = NULL, api_error_status = NULL,
                     stop_reason = NULL) {
    ClaudeAgentSDK::ResultMessage(
      subtype = if (is_error) "error_during_execution" else "success",
      duration_ms = 1, duration_api_ms = 1,
      is_error = is_error, num_turns = 1,
      session_id = "session-terminal-test",
      result = text, api_error_status = api_error_status,
      stop_reason = stop_reason
    )
  }
  assistant <- function(text) ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(text)),
    model = "mock-model", session_id = "session-terminal-test"
  )
  assistant_blocks <- function(...) ClaudeAgentSDK::AssistantMessage(
    content = list(...), model = "mock-model",
    session_id = "session-terminal-test"
  )
  tool_block <- function(id = "assistant-tool") ClaudeAgentSDK::ToolUseBlock(
    id = id, name = "Read", input = list(file_path = "R/handlers.R")
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
  thinking_stream <- function(text) ClaudeAgentSDK::StreamEvent(
    uuid = "thinking-event", session_id = "session-terminal-test",
    event = list(
      type = "content_block_delta", index = 1,
      delta = list(type = "thinking_delta", thinking = text)
    )
  )
  partial_tool_stop <- function() ClaudeAgentSDK::StreamEvent(
    uuid = "partial-tool-stop", session_id = "session-terminal-test",
    event = list(type = "content_block_stop", index = 0)
  )
  task_completed <- function() ClaudeAgentSDK::TaskNotificationMessage(
    subtype = "task_notification", data = list(), task_id = "background-1",
    status = "completed", output_file = tempfile(),
    summary = "locate process_sdtm_data definition", uuid = "task-event",
    session_id = "session-terminal-test"
  )
  tool_result_message <- function(id = "partial-tool", text = "Completed") {
    structure(
      list(content = list(structure(
        list(tool_use_id = id, content = text, is_error = FALSE),
        class = "ToolResultBlock"
      ))),
      class = "UserMessage"
    )
  }

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


  thinking_only <- run_turn(list(
    thinking_stream("I should answer the user now."),
    result(stop_reason = "end_turn")
  ))
  expect_false(thinking_only$done)
  expect_length(thinking_only$chunks, 0L)
  expect_match(thinking_only$error, "user-visible response", ignore.case = TRUE)

  thinking_with_whitespace <- run_turn(list(
    thinking_stream("I should answer after thinking."),
    stream(" \n"),
    result(stop_reason = "end_turn")
  ))
  expect_false(thinking_with_whitespace$done)
  expect_match(
    thinking_with_whitespace$error,
    "without a user-visible response",
    ignore.case = TRUE
  )
  expect_identical(trimws(paste0(thinking_with_whitespace$chunks, collapse = "")), "")

  buffered_whitespace_before_tool <- run_turn(list(
    stream(" "),
    partial_tool_start(),
    partial_tool_stop(),
    result(stop_reason = "end_turn")
  ))
  expect_true(buffered_whitespace_before_tool$done)
  expect_null(buffered_whitespace_before_tool$error)
  expect_length(buffered_whitespace_before_tool$auto_continue, 1L)
  expect_identical(
    trimws(paste0(buffered_whitespace_before_tool$chunks, collapse = "")),
    ""
  )

  stalled_after_tool <- run_turn(list(
    stream("I will verify the assumption first."),
    partial_tool_start(),
    partial_tool_stop(),
    task_completed(),
    thinking_stream("The search timed out; I should ask confirmation questions."),
    result(stop_reason = "end_turn")
  ))
  expect_true(stalled_after_tool$done)
  expect_null(stalled_after_tool$error)
  expect_identical(stalled_after_tool$chunks, "I will verify the assumption first.")
  expect_length(stalled_after_tool$auto_continue, 1L)
  continuation_prompt <- stalled_after_tool$auto_continue[[1L]]$prompt
  expect_match(continuation_prompt, "completed tool results", ignore.case = TRUE)
  expect_match(stalled_after_tool$auto_continue[[1L]]$notice, "Continuing automatically")

  stalled_continuation <- run_turn(
    list(
      partial_tool_start(),
      partial_tool_stop(),
      thinking_stream("I still did not provide visible text."),
      result(stop_reason = "end_turn")
    ),
    message = continuation_prompt
  )
  expect_false(stalled_continuation$done)
  expect_match(stalled_continuation$error, "after a tool call", ignore.case = TRUE)
  expect_length(stalled_continuation$auto_continue, 0L)

  final_after_tool <- run_turn(list(
    partial_tool_start(),
    partial_tool_stop(),
    thinking_stream("Now provide the answer."),
    stream("Here are the confirmation questions."),
    result(stop_reason = "end_turn")
  ))
  expect_true(final_after_tool$done)
  expect_null(final_after_tool$error)
  expect_identical(final_after_tool$chunks, "Here are the confirmation questions.")

  assistant_final_after_tool <- run_turn(list(
    assistant_blocks(
      tool_block(),
      ClaudeAgentSDK::TextBlock("Final text from AssistantMessage.")
    ),
    result(stop_reason = "end_turn")
  ))
  expect_true(assistant_final_after_tool$done)
  expect_null(assistant_final_after_tool$error)
  expect_identical(
    assistant_final_after_tool$chunks,
    "Final text from AssistantMessage."
  )

  result_replays_pre_tool_text <- run_turn(list(
    stream("I will verify first."),
    partial_tool_start(),
    partial_tool_stop(),
    result(text = "I will verify first.", stop_reason = "end_turn")
  ))
  expect_true(result_replays_pre_tool_text$done)
  expect_null(result_replays_pre_tool_text$error)
  expect_length(result_replays_pre_tool_text$auto_continue, 1L)
  expect_identical(result_replays_pre_tool_text$chunks, "I will verify first.")

  assistant_replays_pre_tool_text <- run_turn(list(
    stream("I will verify first."),
    partial_tool_start(),
    partial_tool_stop(),
    assistant("I will verify first."),
    result(stop_reason = "end_turn")
  ))
  expect_true(assistant_replays_pre_tool_text$done)
  expect_null(assistant_replays_pre_tool_text$error)
  expect_length(assistant_replays_pre_tool_text$auto_continue, 1L)
  expect_identical(assistant_replays_pre_tool_text$chunks, "I will verify first.")

  assistant_tool_replays_pre_tool_text <- run_turn(list(
    stream("Preface"),
    partial_tool_start(),
    partial_tool_stop(),
    assistant_blocks(
      tool_block("partial-tool"),
      ClaudeAgentSDK::TextBlock("Preface")
    ),
    result(stop_reason = "end_turn")
  ))
  expect_true(assistant_tool_replays_pre_tool_text$done)
  expect_null(assistant_tool_replays_pre_tool_text$error)
  expect_length(assistant_tool_replays_pre_tool_text$auto_continue, 1L)
  expect_identical(assistant_tool_replays_pre_tool_text$chunks, "Preface")

  whitespace_normalized_replay <- run_turn(list(
    stream("Preface"),
    partial_tool_start(),
    partial_tool_stop(),
    result(text = "\nPreface", stop_reason = "end_turn")
  ))
  expect_true(whitespace_normalized_replay$done)
  expect_null(whitespace_normalized_replay$error)
  expect_length(whitespace_normalized_replay$auto_continue, 1L)
  expect_identical(whitespace_normalized_replay$chunks, "Preface")

  repeated_final_after_tool_result <- run_turn(list(
    stream("I predict 42."),
    partial_tool_start(),
    partial_tool_stop(),
    tool_result_message(),
    assistant("42."),
    result(stop_reason = "end_turn")
  ))
  expect_true(repeated_final_after_tool_result$done)
  expect_null(repeated_final_after_tool_result$error)
  expect_identical(
    paste0(repeated_final_after_tool_result$chunks, collapse = ""),
    "I predict 42.42."
  )

  assistant_preface_before_tool <- run_turn(list(
    assistant_blocks(
      ClaudeAgentSDK::TextBlock("Preface before tool."),
      tool_block("assistant-tool-after-preface")
    ),
    result(stop_reason = "end_turn")
  ))
  expect_true(assistant_preface_before_tool$done)
  expect_null(assistant_preface_before_tool$error)
  expect_length(assistant_preface_before_tool$auto_continue, 1L)
  expect_identical(assistant_preface_before_tool$chunks, "Preface before tool.")

  result_final_after_tool <- run_turn(list(
    partial_tool_start(),
    partial_tool_stop(),
    result(text = "Final text from ResultMessage.", stop_reason = "end_turn")
  ))
  expect_true(result_final_after_tool$done)
  expect_null(result_final_after_tool$error)
  expect_identical(result_final_after_tool$chunks, "Final text from ResultMessage.")

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
