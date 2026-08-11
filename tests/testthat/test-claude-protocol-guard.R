test_that("Claude text guard removes only standalone course_status lines", {
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )

  guard$push("Before\n  course_")
  guard$push("status  \nAfter\n")
  guard$push("course_status report remains\n")
  guard$push("my_course_status remains too")
  guard$finish()

  expect_identical(
    paste0(emitted, collapse = ""),
    "Before\nAfter\ncourse_status report remains\nmy_course_status remains too"
  )
  expect_false(guard$malformed_seen())
})

test_that("Claude text guard stays bounded across many leaked marker lines", {
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )

  for (i in seq_len(2000L)) guard$push("course_status\n")
  guard$push("visible")
  expect_lte(guard$buffered_chars(), 32L)
  guard$finish()

  expect_identical(paste0(emitted, collapse = ""), "visible")
})

test_that("Claude text guard suppresses malformed tool-call prose across chunks", {
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )

  guard$push("Useful preface\ncall <inv")
  guard$push("oke name=\"Read\">\n<parameter name=\"file_path\">x")
  guard$finish()

  expect_identical(paste0(emitted, collapse = ""), "Useful preface\n")
  expect_true(guard$malformed_seen())
})

test_that("Claude text guard does not suppress ordinary protocol discussion", {
  text <- paste(
    "A prose sentence mentioning call <invoke name= is discussion.",
    "`call <invoke name=` is an invalid example inside inline code."
  )
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(value) emitted <<- c(emitted, value)
  )
  guard$push(text)
  guard$finish()

  expect_identical(paste0(emitted, collapse = ""), text)
  expect_false(guard$malformed_seen())
})

test_that("Claude text guard remains bounded after long indentation without leaking markers", {
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )
  guard$push(strrep(" ", 100L))
  expect_lte(guard$buffered_chars(), 32L)
  guard$push("course_")
  guard$push("status\nvisible")
  guard$finish()
  output <- paste0(emitted, collapse = "")
  expect_false(grepl("course_status", output, fixed = TRUE))
  expect_true(endsWith(output, "visible"))

  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )
  guard$push(paste0(strrep(" ", 100L), "call <inv"))
  expect_lte(guard$buffered_chars(), 64L)
  guard$push("oke name=\"Read\">ignored")
  guard$finish()
  expect_true(guard$malformed_seen())
  expect_false(grepl("<invoke", paste0(emitted, collapse = ""), fixed = TRUE))
})

test_that("Claude text guard defers arbitrarily long marker trailing spaces", {
  leaked <- paste0("course_status", strrep(" ", 100L), "\nvisible")
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )
  for (char in strsplit(leaked, "", fixed = TRUE)[[1L]]) guard$push(char)
  expect_lte(guard$buffered_chars(), 32L)
  guard$finish()
  output <- paste0(emitted, collapse = "")
  expect_false(grepl("course_status", output, fixed = TRUE))
  expect_true(endsWith(output, "visible"))

  ordinary <- paste0("course_status", strrep(" ", 100L), "report")
  emitted <- character()
  guard <- shinyAssistantUI:::.new_claude_text_guard(
    function(text) emitted <<- c(emitted, text)
  )
  for (char in strsplit(ordinary, "", fixed = TRUE)[[1L]]) guard$push(char)
  guard$finish()
  expect_identical(paste0(emitted, collapse = ""), ordinary)
})

test_that("Claude text guard preserves protocol examples inside fenced code", {
  for (fence in c("```", "~~~")) {
    text <- paste0(
      "Example:\n", fence, "text\n",
      "call <invoke name=\"Read\">\n",
      fence, "\nAfter"
    )
    emitted <- character()
    guard <- shinyAssistantUI:::.new_claude_text_guard(
      function(value) emitted <<- c(emitted, value)
    )
    split_at <- nchar(text) %/% 2L
    guard$push(substr(text, 1L, split_at))
    guard$push(substr(text, split_at + 1L, nchar(text)))
    guard$finish()

    expect_identical(paste0(emitted, collapse = ""), text)
    expect_false(guard$malformed_seen())
  }
})

test_that("malformed tool prose is never converted into a tool invocation", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  stream <- function(event) ClaudeAgentSDK::StreamEvent(
    uuid = paste0("event-", sample.int(1000000L, 1L)),
    session_id = "session-protocol-test",
    event = event
  )
  result <- function(stop_reason = NULL) ClaudeAgentSDK::ResultMessage(
    subtype = "success", duration_ms = 1, duration_api_ms = 1,
    is_error = FALSE, num_turns = 1, session_id = "session-protocol-test",
    stop_reason = stop_reason
  )
  run_turn <- function(messages) {
    queue <- messages
    client <- new.env(parent = emptyenv())
    client$connect <- function() invisible(NULL)
    client$disconnect <- function() invisible(NULL)
    client$send <- function(content) invisible(NULL)
    client$interrupt <- function(...) invisible(NULL)
    client$approve_tool <- function(...) invisible(NULL)
    client$deny_tool <- function(...) invisible(NULL)
    client$poll_messages <- function() {
      value <- queue
      queue <<- list()
      value
    }
    local_mocked_bindings(
      .new_claude_options = function(...) list(...),
      .new_claude_client = function(options) client
    )
    handler <- make_claude_handler(
      options = list(permission_mode = "default", include_partial_messages = TRUE),
      session_map_path = tempfile(fileext = ".rds")
    )
    captured <- new.env(parent = emptyenv())
    captured$chunks <- character()
    captured$tools <- list()
    captured$error <- NULL
    captured$done <- FALSE
    handler(
      message = "test", thread_id = "protocol-thread", attachments = list(),
      on_chunk = function(text) captured$chunks <- c(captured$chunks, text),
      on_done = function(...) captured$done <- TRUE,
      on_error = function(message) captured$error <- message,
      on_tool_call = function(...) captured$tools[[length(captured$tools) + 1L]] <- list(...),
      on_tool_result = function(...) NULL,
      on_thinking = function(...) NULL,
      is_cancelled = function() FALSE,
      wait_for_approval = function(...) promises::promise_resolve(list(approved = TRUE))
    )
    for (i in seq_len(1000L)) {
      later::run_now()
      if (captured$done || !is.null(captured$error)) break
      Sys.sleep(0.001)
    }
    captured
  }

  malformed <- stream(list(
    type = "content_block_delta", index = 0,
    delta = list(type = "text_delta", text = "call <invoke name=\"Read\">\n")
  ))
  bad <- run_turn(list(malformed, result("tool_use")))
  expect_length(bad$tools, 0L)
  expect_length(bad$chunks, 0L)
  expect_match(bad$error, "protocol", ignore.case = TRUE)

  tool_start <- stream(list(
    type = "content_block_start", index = 1,
    content_block = list(type = "tool_use", id = "real-tool", name = "Read")
  ))
  tool_delta <- stream(list(
    type = "content_block_delta", index = 1,
    delta = list(type = "input_json_delta", partial_json = "{\"file_path\":\"README.md\"}")
  ))
  tool_stop <- stream(list(type = "content_block_stop", index = 1))
  mixed <- run_turn(list(malformed, tool_start, tool_delta, tool_stop, result("tool_use")))
  expect_null(mixed$error)
  expect_true(mixed$done)
  expect_length(mixed$tools, 1L)
  expect_identical(mixed$tools[[1L]]$tool_call_id, "real-tool")

  leaked_marker <- stream(list(
    type = "content_block_delta", index = 0,
    delta = list(type = "text_delta", text = "course_status\n")
  ))
  marker_with_tool <- run_turn(list(
    leaked_marker, tool_start, tool_delta, tool_stop, result("tool_use")
  ))
  expect_null(marker_with_tool$error)
  expect_length(marker_with_tool$chunks, 0L)
  expect_length(marker_with_tool$tools, 1L)

  terminal_only <- ClaudeAgentSDK::AssistantMessage(
    content = list(ClaudeAgentSDK::TextBlock("Answer\ncourse_status\n")),
    model = "mock-model", stop_reason = "end_turn",
    session_id = "session-protocol-test"
  )
  fallback <- run_turn(list(terminal_only, result("end_turn")))
  expect_null(fallback$error)
  expect_identical(paste0(fallback$chunks, collapse = ""), "Answer\n")

  missing_block <- run_turn(list(result("tool_use")))
  expect_length(missing_block$tools, 0L)
  expect_match(missing_block$error, "protocol", ignore.case = TRUE)

  permission_only <- ClaudeAgentSDK::PermissionRequestMessage(
    request_id = "permission-only-request",
    tool_name = "Read",
    tool_input = list(file_path = "README.md"),
    tool_use_id = "permission-only-tool"
  )
  permission_result <- run_turn(list(permission_only, result("tool_use")))
  expect_null(permission_result$error)
  expect_true(permission_result$done)
  expect_length(permission_result$tools, 1L)
  expect_identical(
    permission_result$tools[[1L]]$tool_call_id,
    "permission-only-tool"
  )
})
