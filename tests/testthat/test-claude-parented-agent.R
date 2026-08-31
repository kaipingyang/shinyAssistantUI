test_that("parented Agent text stays out of the top-level stream while nested tools remain", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  stream <- function(text, parent = NULL) ClaudeAgentSDK::StreamEvent(
    uuid = paste0("stream-", if (is.null(parent)) "top" else parent),
    session_id = "parented-agent-test",
    event = list(
      type = "content_block_delta", index = 0,
      delta = list(type = "text_delta", text = text)
    ),
    parent_tool_use_id = parent
  )
  assistant <- function(text, parent = NULL) ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(text)),
    model = "mock-model", session_id = "parented-agent-test",
    parent_tool_use_id = parent
  )
  nested_start <- ClaudeAgentSDK::StreamEvent(
    uuid = "nested-start", session_id = "parented-agent-test",
    event = list(
      type = "content_block_start", index = 7,
      content_block = list(type = "tool_use", id = "nested-read", name = "Read")
    ),
    parent_tool_use_id = "agent-one"
  )
  nested_stop <- ClaudeAgentSDK::StreamEvent(
    uuid = "nested-stop", session_id = "parented-agent-test",
    event = list(type = "content_block_stop", index = 7),
    parent_tool_use_id = "agent-one"
  )
  terminal <- ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "parented-agent-test",
    result = "Top-level summary.", stop_reason = "end_turn"
  )
  queue <- list(
    stream("agent one leaked ", "agent-one"),
    nested_start,
    nested_stop,
    stream("agent two leaked ", "agent-two"),
    assistant("Hidden subagent terminal.", "agent-one"),
    stream("Top-level summary."),
    assistant("Top-level summary."),
    terminal
  )
  client <- new.env(parent = emptyenv())
  client$connect <- client$disconnect <- client$send <- function(...) invisible(NULL)
  client$deny_tool <- client$approve_tool <- client$interrupt <- function(...) invisible(NULL)
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
  chunks <- character()
  tool_starts <- character()
  done <- FALSE
  error <- NULL

  handler(
    message = "", thread_id = "parented-agent-thread", attachments = list(),
    on_chunk = function(text) chunks <<- c(chunks, text),
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_auto_continue = function(...) NULL,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_tool_call_start = function(tool_call_id, ...) {
      tool_starts <<- c(tool_starts, tool_call_id)
    },
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  for (i in seq_len(2000)) {
    later::run_now()
    if (done || !is.null(error)) break
    Sys.sleep(0.002)
  }

  expect_identical(chunks, "Top-level summary.")
  expect_identical(tool_starts, "nested-read")
  expect_true(done)
  expect_null(error)
})
