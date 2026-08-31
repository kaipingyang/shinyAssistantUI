test_that("top-level AssistantMessage after an Agent result is delivered before terminal ResultMessage", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  assistant <- function(text, parent = NULL) ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock(text)),
    model = "mock-model", session_id = "agent-delivery-test",
    parent_tool_use_id = parent
  )
  agent_start <- ClaudeAgentSDK::StreamEvent(
    uuid = "agent-start", session_id = "agent-delivery-test",
    event = list(
      type = "content_block_start", index = 0,
      content_block = list(type = "tool_use", id = "agent-b", name = "Agent")
    )
  )
  agent_stop <- ClaudeAgentSDK::StreamEvent(
    uuid = "agent-stop", session_id = "agent-delivery-test",
    event = list(type = "content_block_stop", index = 0)
  )
  agent_result <- structure(
    list(content = list(structure(
      list(tool_use_id = "agent-b", content = "Agent B completed", is_error = FALSE),
      class = "ToolResultBlock"
    ))),
    class = "UserMessage"
  )
  terminal <- ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "agent-delivery-test",
    result = "Agent B summary is ready.", stop_reason = "end_turn"
  )

  batches <- list(
    list(
      agent_start,
      agent_stop,
      agent_result,
      assistant("Agent B summary is ready."),
      assistant("Hidden child transcript.", parent = "agent-b")
    ),
    list(terminal)
  )
  client <- new.env(parent = emptyenv())
  client$poll_count <- 0L
  client$connect <- client$disconnect <- client$send <- function(...) invisible(NULL)
  client$deny_tool <- client$approve_tool <- client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    client$poll_count <- client$poll_count + 1L
    if (!length(batches)) return(list())
    current <- batches[[1L]]
    batches <<- batches[-1L]
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
  chunk_polls <- integer()
  tool_results <- character()
  done <- FALSE
  error <- NULL
  handler(
    message = "", thread_id = "agent-delivery-thread", attachments = list(),
    on_chunk = function(text) {
      chunks <<- c(chunks, text)
      chunk_polls <<- c(chunk_polls, client$poll_count)
    },
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_auto_continue = function(...) NULL,
    on_tool_call = function(...) NULL,
    on_tool_result = function(tool_call_id, result, ...) {
      tool_results <<- c(tool_results, paste(tool_call_id, result))
    },
    on_tool_call_start = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE))
  )
  for (i in seq_len(1000)) {
    later::run_now()
    if (done || !is.null(error)) break
    Sys.sleep(0.002)
  }

  expect_match(tool_results, "agent-b Agent B completed", fixed = TRUE)
  expect_identical(chunks, "Agent B summary is ready.")
  expect_identical(chunk_polls, 1L)
  expect_true(done)
  expect_null(error)
})
