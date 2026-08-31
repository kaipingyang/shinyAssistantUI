test_that("make_claude_handler never finishes a terminal Claude result silently", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  run_turn <- function(messages, is_cancelled = function() FALSE, message = "",
                       continuation_kind = NULL, legacy_callback = FALSE) {
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
      .claude_drain_timeout_seconds = function() 0.01,
      .package = "shinyAssistantUI"
    )

    handler <- make_claude_handler(
      options = list(
        permission_mode = "default",
        permission_prompt_tool_name = "stdio",
        include_partial_messages = TRUE
      ),
      session_map_path = tempfile(fileext = ".rds")
    )
    cleanup <- attr(handler, "cleanup")
    if (is.function(cleanup)) on.exit(cleanup(), add = TRUE)
    captured <- new.env(parent = emptyenv())
    captured$chunks <- character()
    captured$done <- FALSE
    captured$error <- NULL
    captured$auto_continue <- list()
    captured$tool_starts <- character(0)
    captured$tool_results <- list()

    capture_auto_continue <- function(notice, prompt, kind = NULL) {
      captured$auto_continue[[length(captured$auto_continue) + 1L]] <- list(
        notice = notice, prompt = prompt, kind = kind
      )
    }
    auto_continue_callback <- if (isTRUE(legacy_callback)) {
      function(notice, prompt) capture_auto_continue(notice, prompt)
    } else {
      capture_auto_continue
    }

    handler_args <- list(
      message = message, thread_id = "image-thread",
      attachments = list(list(type = "image", data = "data:image/png;base64,AAAA")),
      on_chunk = function(text) captured$chunks <- c(captured$chunks, text),
      on_done = function(...) captured$done <- TRUE,
      on_error = function(message) captured$error <- message,
      on_auto_continue = auto_continue_callback,
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
    if (!is.null(continuation_kind)) {
      handler_args$continuation_kind <- continuation_kind
    }
    do.call(handler, handler_args)

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
  assistant <- function(text, parent = NULL) ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(text)),
    model = "mock-model", session_id = "session-terminal-test",
    parent_tool_use_id = parent
  )
  assistant_blocks <- function(...) ClaudeAgentSDK::AssistantMessage(
    content = list(...), model = "mock-model",
    session_id = "session-terminal-test"
  )
  thinking_block <- function(text = "Private reasoning.") {
    ClaudeAgentSDK::ThinkingBlock(text, signature = "test-signature")
  }
  tool_block <- function(id = "assistant-tool") ClaudeAgentSDK::ToolUseBlock(
    id = id, name = "Read", input = list(file_path = "R/handlers.R")
  )
  stream <- function(text, parent = NULL) ClaudeAgentSDK::StreamEvent(
    uuid = "stream-event", session_id = "session-terminal-test",
    event = list(
      type = "content_block_delta", index = 0,
      delta = list(type = "text_delta", text = text)
    ),
    parent_tool_use_id = parent
  )
  permission <- function() ClaudeAgentSDK::PermissionRequestMessage(
    request_id = "permission-request",
    tool_name = "Bash",
    tool_input = list(command = "echo test"),
    tool_use_id = "tool-use-terminal-test"
  )
  partial_tool_start <- function(id = "partial-tool", name = "Bash",
                                 parent = NULL, index = 0) ClaudeAgentSDK::StreamEvent(
    uuid = paste0("partial-tool-event-", id), session_id = "session-terminal-test",
    event = list(
      type = "content_block_start", index = index,
      content_block = list(
        type = "tool_use", id = id, name = name
      )
    ),
    parent_tool_use_id = parent
  )
  thinking_stream <- function(text) ClaudeAgentSDK::StreamEvent(
    uuid = "thinking-event", session_id = "session-terminal-test",
    event = list(
      type = "content_block_delta", index = 1,
      delta = list(type = "thinking_delta", thinking = text)
    )
  )
  partial_tool_stop <- function(index = 0) ClaudeAgentSDK::StreamEvent(
    uuid = paste0("partial-tool-stop-", index), session_id = "session-terminal-test",
    event = list(type = "content_block_stop", index = index)
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

  parented_parallel_agents <- run_turn(list(
    stream("agent one leaked ", parent = "agent-one"),
    partial_tool_start(
      id = "nested-read", name = "Read", parent = "agent-one", index = 7
    ),
    partial_tool_stop(index = 7),
    stream("agent two leaked ", parent = "agent-two"),
    stream("Top-level summary."),
    result(text = "Top-level summary.")
  ))
  expect_identical(parented_parallel_agents$chunks, "Top-level summary.")
  expect_identical(parented_parallel_agents$tool_starts, "nested-read")
  expect_true(parented_parallel_agents$done)
  expect_null(parented_parallel_agents$error)

  parented_assistant_terminal <- run_turn(list(
    assistant("Hidden subagent transcript.", parent = "agent-one"),
    assistant("Visible final answer."),
    result(text = "Visible final answer.")
  ))
  expect_identical(parented_assistant_terminal$chunks, "Visible final answer.")
  expect_true(parented_assistant_terminal$done)
  expect_null(parented_assistant_terminal$error)

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
  expect_identical(
    multiple_assistants$chunks,
    c("First answer. ", "Second answer.")
  )
  expect_true(multiple_assistants$done)
  expect_null(multiple_assistants$error)


  thinking_only <- run_turn(list(
    thinking_stream("I should answer the user now."),
    result(stop_reason = "end_turn")
  ))
  expect_true(thinking_only$done)
  expect_null(thinking_only$error)
  expect_length(thinking_only$chunks, 0L)
  expect_length(thinking_only$auto_continue, 1L)
  expect_match(thinking_only$auto_continue[[1L]]$prompt, "visible|final response", ignore.case = TRUE)
  expect_identical(thinking_only$auto_continue[[1L]]$kind, "generic")

  thinking_with_whitespace <- run_turn(list(
    thinking_stream("I should answer after thinking."),
    stream(" \n"),
    result(stop_reason = "end_turn")
  ))
  expect_true(thinking_with_whitespace$done)
  expect_null(thinking_with_whitespace$error)
  expect_length(thinking_with_whitespace$auto_continue, 1L)
  expect_identical(thinking_with_whitespace$auto_continue[[1L]]$kind, "generic")
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
  expect_identical(buffered_whitespace_before_tool$auto_continue[[1L]]$kind, "tool-postlude")
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
  expect_identical(stalled_after_tool$auto_continue[[1L]]$kind, "tool-postlude")

  # The tool-postlude recovery that itself finishes without visible text advances
  # to the distinct generic stage based on hidden metadata, not prompt identity.
  thinking_tool_continuation <- run_turn(
    list(
      thinking_stream("I have the answer and should now state it."),
      result(stop_reason = "end_turn")
    ),
    message = continuation_prompt,
    continuation_kind = "tool-postlude"
  )
  expect_true(thinking_tool_continuation$done)
  expect_null(thinking_tool_continuation$error)
  expect_length(thinking_tool_continuation$auto_continue, 1L)
  generic_prompt <- thinking_tool_continuation$auto_continue[[1L]]$prompt
  expect_false(identical(generic_prompt, continuation_prompt))
  expect_match(generic_prompt, "visible|final response", ignore.case = TRUE)
  expect_identical(thinking_tool_continuation$auto_continue[[1L]]$kind, "generic")

  # Regression: generic recovery may also finish without visible text. It gets
  # exactly one final user-equivalent minimal continuation instead of erroring.
  stalled_generic_continuation <- run_turn(
    list(
      thinking_stream("Still no visible response."),
      result(stop_reason = "end_turn")
    ),
    message = generic_prompt,
    continuation_kind = "generic"
  )
  expect_true(stalled_generic_continuation$done)
  expect_null(stalled_generic_continuation$error)
  expect_length(stalled_generic_continuation$auto_continue, 1L)
  minimal_prompt <- stalled_generic_continuation$auto_continue[[1L]]$prompt
  expect_identical(minimal_prompt, "继续")
  expect_identical(stalled_generic_continuation$auto_continue[[1L]]$kind, "minimal")

  # Successful zero-output generic results use the same minimal fallback.
  empty_generic_continuation <- run_turn(
    list(result(stop_reason = "end_turn")),
    message = generic_prompt,
    continuation_kind = "generic"
  )
  expect_true(empty_generic_continuation$done)
  expect_null(empty_generic_continuation$error)
  expect_identical(empty_generic_continuation$auto_continue[[1L]]$prompt, "继续")
  expect_identical(empty_generic_continuation$auto_continue[[1L]]$kind, "minimal")

  minimal_success <- run_turn(
    list(assistant("最终可见回答。"), result(stop_reason = "end_turn")),
    message = minimal_prompt,
    continuation_kind = "minimal"
  )
  expect_true(minimal_success$done)
  expect_null(minimal_success$error)
  expect_identical(minimal_success$chunks, "最终可见回答。")
  expect_length(minimal_success$auto_continue, 0L)

  # Minimal is the hard bound: no fourth continuation is possible.
  stalled_minimal_continuation <- run_turn(
    list(
      thinking_stream("The minimal continuation still omitted visible text."),
      result(stop_reason = "end_turn")
    ),
    message = minimal_prompt,
    continuation_kind = "minimal"
  )
  expect_false(stalled_minimal_continuation$done)
  expect_match(stalled_minimal_continuation$error, "user-visible response|continuation", ignore.case = TRUE)
  expect_length(stalled_minimal_continuation$auto_continue, 0L)

  # A successful end_turn containing only structured thinking is a distinct
  # terminal failure after the bounded recovery chain. Thinking text may look
  # like a tool call, but it is never parsed or executed as one.
  thinking_only_terminal <- run_turn(
    list(
      assistant_blocks(
        thinking_block("<invoke name=\"Bash\">{\"command\":\"do-not-run\"}</invoke>"),
        ClaudeAgentSDK::TextBlock(" \n")
      ),
      result(stop_reason = "end_turn")
    ),
    message = minimal_prompt,
    continuation_kind = "minimal"
  )
  expect_false(thinking_only_terminal$done)
  expect_match(thinking_only_terminal$error, "thinking-only", ignore.case = TRUE)
  expect_match(thinking_only_terminal$error, "retry", ignore.case = TRUE)
  expect_match(thinking_only_terminal$error, "/compact", fixed = TRUE)
  expect_match(thinking_only_terminal$error, "switch.*model", ignore.case = TRUE)
  expect_length(thinking_only_terminal$auto_continue, 0L)
  expect_length(thinking_only_terminal$tool_starts, 0L)
  expect_length(thinking_only_terminal$tool_results, 0L)
  expect_identical(trimws(paste0(thinking_only_terminal$chunks, collapse = "")), "")

  # Incomplete thinking caused by an output-token limit is not the successful
  # thinking-only/end_turn classification.
  for (limit_reason in c("max_tokens", "max_output_tokens")) {
    incomplete_thinking <- run_turn(
      list(
        assistant_blocks(thinking_block("Incomplete reasoning.")),
        result(stop_reason = limit_reason)
      ),
      message = minimal_prompt,
      continuation_kind = "minimal"
    )
    expect_false(incomplete_thinking$done, info = limit_reason)
    expect_match(
      incomplete_thinking$error,
      "user-visible response|continuation",
      ignore.case = TRUE,
      info = limit_reason
    )
    expect_false(
      grepl("thinking-only", incomplete_thinking$error, ignore.case = TRUE),
      info = limit_reason
    )
    expect_length(incomplete_thinking$auto_continue, 0L)
  }

  # Visible text never identifies an internal stage. A human typing exactly
  # “继续”, or an unknown metadata value, remains an ordinary turn.
  manual_continue <- run_turn(
    list(thinking_stream("Manual continue also needs recovery."), result(stop_reason = "end_turn")),
    message = "继续"
  )
  expect_true(manual_continue$done)
  expect_null(manual_continue$error)
  expect_identical(manual_continue$auto_continue[[1L]]$kind, "generic")

  unknown_kind <- run_turn(
    list(thinking_stream("Unknown kind is ordinary."), result(stop_reason = "end_turn")),
    message = generic_prompt,
    continuation_kind = "forged-unknown"
  )
  expect_true(unknown_kind$done)
  expect_null(unknown_kind$error)
  expect_identical(unknown_kind$auto_continue[[1L]]$kind, "generic")

  legacy_callback <- run_turn(
    list(thinking_stream("Old callback remains valid."), result(stop_reason = "end_turn")),
    legacy_callback = TRUE
  )
  expect_true(legacy_callback$done)
  expect_null(legacy_callback$error)
  expect_length(legacy_callback$auto_continue, 1L)

  # Any internal recovery stage that starts a new tool and again omits final
  # text fails closed instead of entering another tool-postlude loop.
  stalled_continuation <- run_turn(
    list(
      partial_tool_start(),
      partial_tool_stop(),
      thinking_stream("I still did not provide visible text."),
      result(stop_reason = "end_turn")
    ),
    message = continuation_prompt,
    continuation_kind = "tool-postlude"
  )
  expect_false(stalled_continuation$done)
  expect_match(stalled_continuation$error, "after a tool call", ignore.case = TRUE)
  expect_length(stalled_continuation$auto_continue, 0L)

  stalled_generic_with_tool <- run_turn(
    list(
      partial_tool_start(),
      partial_tool_stop(),
      thinking_stream("The generic recovery still omitted visible text."),
      result(stop_reason = "end_turn")
    ),
    message = generic_prompt,
    continuation_kind = "generic"
  )
  expect_false(stalled_generic_with_tool$done)
  expect_match(stalled_generic_with_tool$error, "after a tool call", ignore.case = TRUE)
  expect_length(stalled_generic_with_tool$auto_continue, 0L)

  stalled_minimal_with_tool <- run_turn(
    list(
      partial_tool_start(),
      partial_tool_stop(),
      thinking_stream("The minimal recovery still omitted visible text."),
      result(stop_reason = "end_turn")
    ),
    message = minimal_prompt,
    continuation_kind = "minimal"
  )
  expect_false(stalled_minimal_with_tool$done)
  expect_match(stalled_minimal_with_tool$error, "after a tool call", ignore.case = TRUE)
  expect_length(stalled_minimal_with_tool$auto_continue, 0L)

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

  terminal_suffix <- getFromNamespace(
    ".claude_terminal_suffix",
    "shinyAssistantUI"
  )
  expect_identical(terminal_suffix(character(), "terminal"), "terminal")
  expect_identical(terminal_suffix(NA_character_, "terminal"), "terminal")
  expect_identical(terminal_suffix("stream", NA_character_), "")
})
