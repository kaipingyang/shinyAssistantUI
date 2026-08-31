test_that("Claude UI tool result preview bounds oversized values only", {
  withr::local_options(shinyAssistantUI.claude_tool_result_max_bytes = 4096L)

  expect_identical(.claude_ui_tool_result("small"), "small")
  expect_identical(.claude_ui_tool_result(list(value = "small")), list(value = "small"))

  text <- .claude_ui_tool_result(strrep("x", 16384L))
  expect_type(text, "character")
  expect_lte(nchar(text, type = "bytes"), 4096L)
  expect_match(text, "UI preview truncated", fixed = TRUE)

  structured <- .claude_ui_tool_result(list(payload = strrep("y", 16384L)))
  expect_type(structured, "character")
  expect_lte(nchar(structured, type = "bytes"), 4096L)
  expect_match(structured, "UI preview omitted", fixed = TRUE)
})

test_that("historical tool results use the same bounded preview", {
  withr::local_options(shinyAssistantUI.claude_tool_result_max_bytes = 512L)
  msgs <- list(
    list(
      type = "user", uuid = "u-result",
      message = list(content = list(list(
        type = "tool_result", tool_use_id = "tool-large",
        content = strrep("r", 2048L), is_error = FALSE
      )))
    ),
    list(
      type = "assistant", uuid = "a-tool",
      message = list(content = list(list(
        type = "tool_use", id = "tool-large", name = "Bash", input = list(command = "x")
      )))
    )
  )

  thread <- .claude_msgs_to_thread(msgs)
  result <- thread[[1L]]$content[[1L]]$result
  expect_lte(nchar(result, type = "bytes"), 512L)
  expect_match(result, "UI preview truncated", fixed = TRUE)
})

test_that("compact summary metadata renders as completed assistant history", {
  compact <- list(
    type = "user", uuid = "compact-1", is_compact_summary = TRUE,
    is_visible_in_transcript_only = TRUE,
    message = list(role = "user", content = "authoritative summary")
  )
  ordinary <- list(
    type = "user", uuid = "user-1",
    message = list(role = "user", content = "ordinary prompt")
  )

  compact_thread <- .claude_msgs_to_thread(list(compact))
  ordinary_thread <- .claude_msgs_to_thread(list(ordinary))

  expect_identical(compact_thread[[1L]]$role, "assistant")
  expect_identical(compact_thread[[1L]]$status, list(type = "complete", reason = "stop"))
  expect_identical(compact_thread[[1L]]$content[[1L]]$text, "authoritative summary")
  expect_identical(ordinary_thread[[1L]]$role, "user")
})

test_that("live oversized result is bounded for UI and reclaims once", {
  withr::local_options(shinyAssistantUI.claude_tool_result_max_bytes = 512L)
  queue <- list(
    structure(list(
      content = list(structure(list(
        tool_use_id = "tool-large", content = strrep("z", 2048L), is_error = FALSE
      ), class = c("ToolResultBlock", "list"))),
      tool_use_result = list(payload = strrep("z", 2048L))
    ), class = c("UserMessage", "list")),
    structure(list(
      is_error = FALSE, result = "done", session_id = "large-result-session",
      stop_reason = "end_turn", usage = list(), total_cost_usd = NULL,
      num_turns = 1L, duration_ms = 1
    ), class = c("ResultMessage", "list"))
  )
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    if (!length(queue)) return(list())
    value <- queue[[1L]]
    queue <<- queue[-1L]
    list(value)
  }
  gc_calls <- 0L
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_full_gc = function() { gc_calls <<- gc_calls + 1L; invisible(NULL) }
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "bypassPermissions",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  captured <- NULL
  done <- FALSE
  error <- NULL
  handler(
    message = "large", thread_id = "large-result-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(value) error <<- value,
    on_tool_call = function(...) NULL,
    on_tool_result = function(tool_call_id, result, is_error) captured <<- result,
    on_tool_call_start = function(...) NULL,
    on_tool_call_delta = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = TRUE))
  )
  for (i in seq_len(2000L)) {
    later::run_now()
    if (done || !is.null(error)) break
    Sys.sleep(0.001)
  }

  expect_null(error)
  expect_true(done)
  expect_type(captured, "character")
  expect_match(captured, "UI preview omitted", fixed = TRUE)
  expect_identical(gc_calls, 1L)
})


test_that("raw transcript compact metadata is recovered by UUID for older SDKs", {
  transcript <- tempfile(fileext = ".jsonl")
  on.exit(unlink(transcript), add = TRUE)
  writeLines(c(
    as.character(jsonlite::toJSON(list(
      type = "user", uuid = "ordinary-1", message = list(content = "prompt")
    ), auto_unbox = TRUE)),
    as.character(jsonlite::toJSON(list(
      type = "user", uuid = "compact-raw", isCompactSummary = TRUE,
      isVisibleInTranscriptOnly = TRUE, message = list(content = "summary")
    ), auto_unbox = TRUE))
  ), transcript)
  messages <- list(
    structure(list(type = "user", uuid = "ordinary-1"), class = c("SessionMessage", "list")),
    structure(list(type = "user", uuid = "compact-raw"), class = c("SessionMessage", "list"))
  )

  annotated <- .annotate_claude_compact_summaries(messages, transcript)

  expect_null(annotated[[1L]]$is_compact_summary)
  expect_true(annotated[[2L]]$is_compact_summary)
  expect_true(annotated[[2L]]$is_visible_in_transcript_only)
  expect_s3_class(annotated[[2L]], "SessionMessage")
})


test_that("structured preview uses a conservative serialized-size estimate", {
  withr::local_options(shinyAssistantUI.claude_tool_result_max_bytes = 1024L * 1024L)
  result <- list(values = rep(.Machine$integer.max, 100000L))

  expect_true(.claude_tool_result_is_oversized(result))
  preview <- .claude_ui_tool_result(result)
  expect_type(preview, "character")
  expect_match(preview, "UI preview omitted", fixed = TRUE)
})


test_that("oversized advisor result clears StreamEvent bindings before full GC", {
  withr::local_options(shinyAssistantUI.claude_tool_result_max_bytes = 512L)
  queue <- list(
    structure(list(
      event = list(
        type = "content_block_start", index = 0L,
        content_block = list(
          type = "advisor_tool_result", tool_use_id = "advisor-large",
          content = list(payload = strrep("a", 2048L))
        )
      ),
      parent_tool_use_id = NULL
    ), class = c("StreamEvent", "list")),
    structure(list(
      is_error = FALSE, result = "done", session_id = "advisor-result-session",
      stop_reason = "end_turn", usage = list(), total_cost_usd = NULL,
      num_turns = 1L, duration_ms = 1
    ), class = c("ResultMessage", "list"))
  )
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    if (!length(queue)) return(list())
    value <- queue[[1L]]
    queue <<- queue[-1L]
    list(value)
  }
  gc_bindings_cleared <- FALSE
  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .claude_full_gc = function() {
      caller <- parent.frame()
      binding_names <- c("msg", "evt", "blk", "delta", "advisor_result")
      gc_bindings_cleared <<- all(vapply(binding_names, function(name) {
        !exists(name, envir = caller, inherits = FALSE) ||
          is.null(get(name, envir = caller, inherits = FALSE))
      }, logical(1)))
      invisible(NULL)
    }
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "bypassPermissions",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  captured <- NULL
  done <- FALSE
  error <- NULL
  handler(
    message = "advisor", thread_id = "advisor-result-thread", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(value) error <<- value,
    on_tool_call = function(...) NULL,
    on_tool_result = function(tool_call_id, result, is_error) captured <<- result,
    on_tool_call_start = function(...) NULL,
    on_tool_call_delta = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = TRUE))
  )
  for (i in seq_len(2000L)) {
    later::run_now()
    if (done || !is.null(error)) break
    Sys.sleep(0.001)
  }

  expect_null(error)
  expect_true(done)
  expect_match(captured, "UI preview omitted", fixed = TRUE)
  expect_true(gc_bindings_cleared)
})
