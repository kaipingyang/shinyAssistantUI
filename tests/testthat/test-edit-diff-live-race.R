make_edit_stream_event <- function(type, index = 0L, content_block = NULL, delta = NULL) {
  event <- list(type = type, index = index)
  if (!is.null(content_block)) event$content_block <- content_block
  if (!is.null(delta)) event$delta <- delta
  structure(
    list(event = event, parent_tool_use_id = NULL),
    class = "StreamEvent"
  )
}

make_edit_result_message <- function(blocks, structured_result = NULL) {
  structure(
    list(content = blocks, tool_use_result = structured_result),
    class = "UserMessage"
  )
}

make_tool_result_block <- function(id, content = "Edited", is_error = FALSE) {
  structure(
    list(tool_use_id = id, content = content, is_error = is_error),
    class = "ToolResultBlock"
  )
}

make_terminal_result <- function(text = "done") {
  structure(
    list(
      is_error = FALSE, result = text, session_id = "edit-race-session",
      stop_reason = "end_turn", usage = list(), total_cost_usd = NULL,
      num_turns = 1L, duration_ms = 1
    ),
    class = "ResultMessage"
  )
}

run_edit_race_batch <- function(messages, approval = list(approved = TRUE)) {
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
    options = list(
      permission_mode = "bypassPermissions",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  captured <- new.env(parent = emptyenv())
  captured$tool_calls <- list()
  captured$tool_results <- list()
  captured$order <- character()
  captured$chunks <- character()
  captured$done <- FALSE
  captured$error <- NULL

  handler(
    message = "edit", thread_id = "edit-race-thread", attachments = list(),
    on_chunk = function(text) captured$chunks <- c(captured$chunks, text),
    on_done = function(...) captured$done <- TRUE,
    on_error = function(message) captured$error <- message,
    on_tool_call = function(tool_call_id, tool_name, args, annotations = list()) {
      captured$order <- c(captured$order, paste0("call:", tool_call_id))
      captured$tool_calls[[length(captured$tool_calls) + 1L]] <- list(
        id = tool_call_id, name = tool_name, args = args, annotations = annotations
      )
    },
    on_tool_result = function(tool_call_id, result, is_error) {
      captured$order <- c(captured$order, paste0("result:", tool_call_id))
      captured$tool_results[[length(captured$tool_results) + 1L]] <- list(
        id = tool_call_id, result = result, is_error = is_error
      )
    },
    on_tool_call_start = function(...) NULL,
    on_tool_call_delta = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(approval)
  )
  for (i in seq_len(2000L)) {
    later::run_now()
    if (captured$done || !is.null(captured$error)) break
    Sys.sleep(0.001)
  }
  captured
}

edit_stream_messages <- function(
    id = "edit-race", old = "target <- old", new = "target <- new",
    result_error = FALSE, structured = TRUE, index = 0L) {
  args <- list(
    file_path = "demo.R", old_string = old,
    new_string = new, replace_all = FALSE
  )
  result <- if (structured) list(
    filePath = "demo.R", oldString = old, newString = new,
    originalFile = paste(c("line1", "line2", "line3", old, "line5"), collapse = "\n"),
    structuredPatch = list(), userModified = FALSE, replaceAll = FALSE
  ) else NULL
  list(
    make_edit_stream_event(
      "content_block_start", index = index, content_block = list(
        type = "tool_use", id = id, name = "Edit"
      )
    ),
    make_edit_stream_event(
      "content_block_delta", index = index,
      delta = list(
        type = "input_json_delta",
        partial_json = as.character(jsonlite::toJSON(args, auto_unbox = TRUE))
      )
    ),
    make_edit_stream_event("content_block_stop", index = index),
    make_edit_result_message(
      list(make_tool_result_block(id, is_error = result_error)),
      result
    ),
    make_terminal_result()
  )
}

test_that("Auto-edit recovers diffStartLine from originalFile before publishing result", {
  captured <- run_edit_race_batch(edit_stream_messages())

  expect_null(captured$error)
  expect_true(captured$done)
  expect_length(captured$tool_calls, 2L)
  expect_identical(vapply(captured$tool_calls, `[[`, character(1), "id"),
                   c("edit-race", "edit-race"))
  expect_null(captured$tool_calls[[1L]]$annotations$diffStartLine)
  expect_identical(captured$tool_calls[[2L]]$annotations$diffStartLine, 4L)
  expect_identical(captured$tool_calls[[2L]]$args, captured$tool_calls[[1L]]$args)
  expect_identical(
    captured$order[seq_len(3L)],
    c("call:edit-race", "call:edit-race", "result:edit-race")
  )
})

test_that("error Edit results never recover a line even with originalFile", {
  captured <- run_edit_race_batch(edit_stream_messages(result_error = TRUE))
  expect_length(captured$tool_calls, 1L)
  expect_null(captured$tool_calls[[1L]]$annotations$diffStartLine)
  expect_true(captured$tool_results[[1L]]$is_error)
})

test_that("parallel multi-block results never bind one structured payload to the wrong Edit", {
  first <- edit_stream_messages(id = "edit-a")
  second <- edit_stream_messages(
    id = "edit-b", old = "other <- old", new = "other <- new", index = 1L
  )
  messages <- c(
    first[1:3], second[1:3],
    list(make_edit_result_message(
      list(make_tool_result_block("edit-b"), make_tool_result_block("edit-a")),
      list(
        filePath = "demo.R", oldString = "target <- old",
        newString = "target <- new",
        originalFile = "line1\nline2\nline3\ntarget <- old\nline5",
        replaceAll = FALSE
      )
    )),
    list(make_terminal_result())
  )
  captured <- run_edit_race_batch(messages)

  expect_length(captured$tool_calls, 2L)
  expect_setequal(
    vapply(captured$tool_calls, `[[`, character(1), "id"),
    c("edit-a", "edit-b")
  )
  expect_true(all(vapply(
    captured$tool_calls,
    function(call) is.null(call$annotations$diffStartLine),
    logical(1)
  )))
})


test_that("Manual approval recovery preserves annotations and effective updatedInput", {
  streamed <- edit_stream_messages(id = "edit-manual")
  streamed <- streamed[1:3]
  for (index in seq_along(streamed)) {
    streamed[[index]]$parent_tool_use_id <- "parent-task"
  }
  original_args <- list(
    file_path = "demo.R", old_string = "target <- old",
    new_string = "target <- proposed", replace_all = FALSE
  )
  # Match the stream canonical args to the PermissionRequest's initial input.
  streamed[[2L]]$event$delta$partial_json <- as.character(jsonlite::toJSON(
    original_args, auto_unbox = TRUE
  ))
  permission <- structure(
    list(
      request_id = "request-manual", tool_use_id = "edit-manual",
      tool_name = "Edit", tool_input = original_args,
      suggestions = list(list(type = "setMode", mode = "acceptEdits")),
      title = "Approve edit", display_name = "Edit", description = "demo.R"
    ),
    class = "PermissionRequestMessage"
  )
  effective_args <- utils::modifyList(
    original_args, list(new_string = "target <- approved")
  )
  result <- list(
    filePath = "demo.R", oldString = "target <- old",
    newString = "target <- approved",
    originalFile = "line1\nline2\nline3\ntarget <- old\nline5",
    replaceAll = FALSE
  )
  captured <- run_edit_race_batch(
    c(
      streamed,
      list(permission),
      list(make_edit_result_message(
        list(make_tool_result_block("edit-manual")), result
      )),
      list(make_terminal_result())
    ),
    approval = list(
      approved = TRUE,
      updatedInput = list(new_string = "target <- approved")
    )
  )

  expect_null(captured$error)
  expect_true(captured$done)
  expect_length(captured$tool_calls, 3L)
  recovered <- captured$tool_calls[[3L]]
  expect_identical(recovered$args, effective_args)
  expect_identical(recovered$annotations$diffStartLine, 4L)
  expect_true(recovered$annotations$requiresApproval)
  expect_identical(recovered$annotations$parentToolCallId, "parent-task")
  expect_identical(recovered$annotations$title, "Approve edit")
  expect_identical(
    tail(captured$order, 2L),
    c("call:edit-manual", "result:edit-manual")
  )
})
