test_that("PermissionRequest recovers complete streamed AskUserQuestion args", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  run_case <- function(streamed_input, permission_input) {
    tool_id <- paste0("ask-recovery-", sample.int(1000000L, 1L))
    stream <- function(event) ClaudeAgentSDK::StreamEvent(
      uuid = paste0("event-", sample.int(1000000L, 1L)),
      session_id = "session-ask-recovery",
      event = event
    )
    messages <- list(
      stream(list(
        type = "content_block_start", index = 0,
        content_block = list(type = "tool_use", id = tool_id, name = "AskUserQuestion")
      )),
      stream(list(
        type = "content_block_delta", index = 0,
        delta = list(
          type = "input_json_delta",
          partial_json = as.character(jsonlite::toJSON(streamed_input, auto_unbox = TRUE))
        )
      )),
      ClaudeAgentSDK::PermissionRequestMessage(
        request_id = paste0("permission-", tool_id),
        tool_name = "AskUserQuestion",
        tool_input = permission_input,
        tool_use_id = tool_id
      ),
      stream(list(type = "content_block_stop", index = 0)),
      ClaudeAgentSDK::ResultMessage(
        subtype = "success", duration_ms = 1, duration_api_ms = 1,
        is_error = FALSE, num_turns = 1,
        session_id = "session-ask-recovery", result = "done",
        stop_reason = "end_turn"
      )
    )

    client <- new.env(parent = emptyenv())
    client$connect <- function() invisible(NULL)
    client$disconnect <- function() invisible(NULL)
    client$send <- function(content) invisible(NULL)
    client$interrupt <- function(...) invisible(NULL)
    client$approve_tool <- function(...) invisible(NULL)
    client$deny_tool <- function(...) invisible(NULL)
    client$poll_messages <- function() {
      value <- messages
      messages <<- list()
      value
    }

    local_mocked_bindings(
      .new_claude_options = function(...) list(...),
      .new_claude_client = function(options) client
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
    captured$tools <- list()
    captured$done <- FALSE
    captured$error <- NULL

    handler(
      message = "test", thread_id = paste0("ask-recovery-", tool_id),
      attachments = list(),
      on_chunk = function(...) NULL,
      on_done = function(...) captured$done <- TRUE,
      on_error = function(message) captured$error <- message,
      on_tool_call = function(...) {
        captured$tools[[length(captured$tools) + 1L]] <- list(...)
      },
      on_tool_result = function(...) NULL,
      on_thinking = function(...) NULL,
      is_cancelled = function() FALSE,
      wait_for_approval = function(...) {
        promises::promise_resolve(list(approved = TRUE))
      }
    )

    for (index in seq_len(1000L)) {
      later::run_now()
      if (captured$done || !is.null(captured$error)) break
      Sys.sleep(0.001)
    }
    captured
  }

  streamed <- list(questions = list(list(
    question = "Choose?", header = "Choice", multiSelect = FALSE,
    options = list(list(label = "Streamed", description = "Recovered option"))
  )))
  recovered <- run_case(streamed, list())

  expect_true(recovered$done)
  expect_null(recovered$error)
  expect_length(recovered$tools, 1L)
  expect_identical(recovered$tools[[1L]]$tool_name, "AskUserQuestion")
  expect_identical(recovered$tools[[1L]]$args, streamed)
  expect_true(isTRUE(recovered$tools[[1L]]$annotations$requiresApproval))

  streamed_with_answers <- utils::modifyList(
    streamed,
    list(answers = list("Choose?" = "Streamed"))
  )
  permission_questions <- list(questions = list(list(
    question = "Choose?", header = "Choice", multiSelect = FALSE,
    options = list(list(label = "Permission", description = "Authoritative option"))
  )))
  overlaid <- run_case(streamed_with_answers, permission_questions)

  expect_true(overlaid$done)
  expect_null(overlaid$error)
  expect_length(overlaid$tools, 1L)
  expect_identical(overlaid$tools[[1L]]$args$questions, permission_questions$questions)
  expect_identical(overlaid$tools[[1L]]$args$answers, streamed_with_answers$answers)
})
