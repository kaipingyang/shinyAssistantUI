submit_edit_diff_test <- function(session, thread_id = "thread-1", text = "edit") {
  session$flushReact()
  session$setInputs(chat_input = list(
    text = text, threadId = thread_id,
    runId = paste0("run-", thread_id), ts = as.numeric(Sys.time())
  ))
  session$flushReact()
  deadline <- Sys.time() + 0.2
  repeat {
    later::run_now(0)
    if (Sys.time() >= deadline) break
    Sys.sleep(0.005)
  }
  later::run_now(0)
  invisible(NULL)
}

test_that("Claude tool metadata sidecar records only valid Edit diff line numbers", {
  d <- tempfile("tool-metadata-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  map_path <- file.path(d, "session_map.rds")
  path <- shinyAssistantUI:::.claude_tool_metadata_path(map_path)

  expect_identical(basename(path), "tool_metadata.rds")
  expect_identical(shinyAssistantUI:::.read_tool_metadata(path), list())
  expect_null(shinyAssistantUI:::.claude_tool_metadata_path(NULL))
  expect_null(shinyAssistantUI:::.claude_tool_metadata_path(""))

  shinyAssistantUI:::.record_tool_metadata(
    path, "edit-1", "Edit",
    list(diffStartLine = 4L, inputId = "secret-widget", title = "not persisted")
  )
  shinyAssistantUI:::.record_tool_metadata(
    path, "edit-2", "Edit", list(diffStartLine = 9)
  )
  stored <- shinyAssistantUI:::.read_tool_metadata(path)
  expect_identical(stored$`edit-1`, list(diffStartLine = 4L))
  expect_identical(stored$`edit-2`, list(diffStartLine = 9L))
  expect_null(stored$`edit-1`$inputId)
  expect_null(stored$`edit-1`$title)

  invalid <- list(NA_real_, Inf, 0, -1, 1.5, "4", c(4, 5), NULL)
  for (i in seq_along(invalid)) {
    shinyAssistantUI:::.record_tool_metadata(
      path, paste0("bad-", i), "Edit", list(diffStartLine = invalid[[i]])
    )
  }
  shinyAssistantUI:::.record_tool_metadata(
    path, "bash-1", "Bash", list(diffStartLine = 12L)
  )
  shinyAssistantUI:::.record_tool_metadata(
    path, "", "Edit", list(diffStartLine = 12L)
  )
  stored <- shinyAssistantUI:::.read_tool_metadata(path)
  expect_setequal(names(stored), c("edit-1", "edit-2"))

  writeLines("not an rds", path)
  expect_identical(shinyAssistantUI:::.read_tool_metadata(path), list())
})

test_that("Claude tool metadata pruning removes only requested tool ids", {
  d <- tempfile("tool-metadata-prune-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  path <- file.path(d, "tool_metadata.rds")
  for (id in c("edit-a", "edit-b", "edit-c")) {
    shinyAssistantUI:::.record_tool_metadata(
      path, id, "Edit", list(diffStartLine = match(id, c("edit-a", "edit-b", "edit-c")))
    )
  }
  shinyAssistantUI:::.prune_tool_metadata(path, c("edit-a", "edit-c"))
  expect_identical(
    shinyAssistantUI:::.read_tool_metadata(path),
    list(`edit-b` = list(diffStartLine = 2L))
  )
  expect_null(shinyAssistantUI:::.prune_tool_metadata(path, character()))
  expect_null(shinyAssistantUI:::.prune_tool_metadata(NULL, "edit-b"))
})

test_that("Claude history restores persisted Edit diffStartLine without changing legacy artifacts", {
  msgs <- list(
    list(type = "assistant", uuid = "a1", message = list(content = list(
      list(
        type = "tool_use", id = "edit-history-1", name = "Edit",
        input = list(
          file_path = "demo.R", old_string = "target <- old",
          new_string = "target <- new"
        )
      ),
      list(
        type = "tool_use", id = "bash-history-1", name = "Bash",
        input = list(command = "echo ok")
      )
    ))),
    list(type = "user", uuid = "u1", message = list(content = list(
      list(
        type = "tool_result", tool_use_id = "edit-history-1",
        content = "Edited", is_error = FALSE
      ),
      list(
        type = "tool_result", tool_use_id = "bash-history-1",
        content = "ok", is_error = FALSE
      )
    )))
  )

  legacy <- shinyAssistantUI:::.claude_msgs_to_thread(
    msgs, list(`edit-history-1` = "approved")
  )
  legacy_edit <- legacy[[1]]$content[[1]]
  expect_null(legacy_edit$artifact$diffStartLine)
  expect_identical(legacy_edit$artifact$approvalResult, "approved")

  restored <- shinyAssistantUI:::.claude_msgs_to_thread(
    msgs,
    decisions = list(`edit-history-1` = "approved"),
    metadata = list(
      `edit-history-1` = list(diffStartLine = 4L),
      `bash-history-1` = list(diffStartLine = 99L)
    )
  )
  edit <- restored[[1]]$content[[1]]
  bash <- restored[[1]]$content[[2]]
  expect_identical(edit$artifact$diffStartLine, 4L)
  expect_identical(edit$artifact$approvalResult, "approved")
  expect_false(edit$artifact$isError)
  expect_null(bash$artifact$diffStartLine)
})

test_that("assistantUIServer records enriched Edit metadata before sending the canonical card", {
  d <- tempfile("edit-server-hook-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  writeLines(c("a <- 1", "b <- 2", "c <- 3", "target <- old"), file.path(d, "demo.R"))
  recorded <- list()
  order <- character()
  sent <- list()

  handler <- function(on_tool_call, on_done, ...) {
    on_tool_call(
      "edit-live-1", "Edit",
      list(
        file_path = "demo.R", old_string = "target <- old",
        new_string = "target <- new"
      ),
      list(title = "Edit demo.R")
    )
    on_done()
  }
  attr(handler, "record_tool_metadata") <- function(
      tool_call_id, tool_name, annotations, thread_id, project) {
    order <<- c(order, "record")
    recorded[[length(recorded) + 1L]] <<- list(
      tool_call_id = tool_call_id, tool_name = tool_name,
      annotations = annotations, thread_id = thread_id, project = project
    )
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, working_dir = d)
  }, {
    session$sendCustomMessage <- function(type, message) {
      if (identical(type, "chat_input:tool-call")) order <<- c(order, "send")
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_edit_diff_test(session, "thread-1", "edit")
  })

  expect_identical(order, c("record", "send"))
  expect_length(recorded, 1L)
  expect_identical(recorded[[1]]$tool_call_id, "edit-live-1")
  expect_identical(recorded[[1]]$tool_name, "Edit")
  expect_identical(recorded[[1]]$annotations$diffStartLine, 4L)
  tool_message <- Filter(
    function(x) identical(x$type, "chat_input:tool-call"), sent
  )[[1]]$message
  expect_identical(tool_message$annotations$diffStartLine, 4L)
})

test_that("metadata recorder failures never suppress the live tool-call payload", {
  d <- tempfile("edit-server-hook-failure-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  writeLines(c("one", "two", "target"), file.path(d, "demo.R"))
  sent <- list()
  handler <- function(on_tool_call, on_done, ...) {
    on_tool_call(
      "edit-live-failure", "Edit",
      list(file_path = "demo.R", old_string = "target", new_string = "changed")
    )
    on_done()
  }
  attr(handler, "record_tool_metadata") <- function(...) stop("sidecar unavailable")

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, working_dir = d)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    expect_silent(submit_edit_diff_test(session, "thread-1", "edit"))
  })

  tool_messages <- Filter(
    function(x) identical(x$type, "chat_input:tool-call"), sent
  )
  expect_length(tool_messages, 1L)
  expect_identical(tool_messages[[1]]$message$annotations$diffStartLine, 3L)
})

test_that("make_claude_session_loader reads Edit metadata for each new traversal", {
  d <- tempfile("edit-loader-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  map_path <- file.path(d, "session_map.rds")
  metadata_path <- shinyAssistantUI:::.claude_tool_metadata_path(map_path)
  raw <- list(list(type = "assistant", uuid = "a1", message = list(content = list(
    list(
      type = "tool_use", id = "edit-loader-1", name = "Edit",
      input = list(file_path = "demo.R", old_string = "old", new_string = "new")
    )
  ))))
  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) raw
  )
  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, "edit-loader-1", "Edit", list(diffStartLine = 7L)
  )
  loader <- make_claude_session_loader(map_path)
  pages <- list()
  capture <- function(messages, ...) {
    pages[[length(pages) + 1L]] <<- messages
    messages
  }

  loader("session-1", "thread-1", capture)
  expect_identical(pages[[1]][[1]]$content[[1]]$artifact$diffStartLine, 7L)

  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, "edit-loader-1", "Edit", list(diffStartLine = 11L)
  )
  loader("session-1", "thread-1", capture)
  expect_identical(pages[[2]][[1]]$content[[1]]$artifact$diffStartLine, 11L)
})


test_that("Claude session deletion prunes decisions and Edit metadata using the workspace directory", {
  d <- tempfile("edit-delete-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  project <- file.path(d, "workspace"); dir.create(project)
  map_path <- file.path(d, "session_map.rds")
  saveRDS(list(thread = "session-delete"), map_path)
  decisions_path <- shinyAssistantUI:::.claude_decisions_path(map_path)
  metadata_path <- shinyAssistantUI:::.claude_tool_metadata_path(map_path)
  shinyAssistantUI:::.record_tool_decision(decisions_path, "edit-delete", "approved")
  shinyAssistantUI:::.record_tool_decision(decisions_path, "keep", "denied")
  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, "edit-delete", "Edit", list(diffStartLine = 6L)
  )
  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, "keep", "Edit", list(diffStartLine = 8L)
  )
  directories <- character()
  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      directories <<- c(directories, directory)
      list(list(type = "assistant", message = list(content = list(
        list(type = "tool_use", id = "edit-delete", name = "Edit", input = list())
      ))))
    },
    .delete_claude_session = function(session_id, directory = NULL) TRUE
  )
  handler <- structure(function(...) NULL,
                       release_session = function(session_id) character())

  ok <- shinyAssistantUI:::.claude_delete_session(
    "session-delete", project = project, handler = handler,
    archived_path = file.path(d, "archived.rds"), session_map_path = map_path
  )
  expect_true(ok)
  expect_identical(directories, project)
  expect_null(shinyAssistantUI:::.read_tool_decisions(decisions_path)$`edit-delete`)
  expect_identical(shinyAssistantUI:::.read_tool_decisions(decisions_path)$keep, "denied")
  expect_null(shinyAssistantUI:::.read_tool_metadata(metadata_path)$`edit-delete`)
  expect_identical(
    shinyAssistantUI:::.read_tool_metadata(metadata_path)$keep,
    list(diffStartLine = 8L)
  )
})

test_that("failed Claude session deletion retains Edit metadata", {
  d <- tempfile("edit-delete-failure-"); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  map_path <- file.path(d, "session_map.rds")
  saveRDS(list(thread = "session-failure"), map_path)
  metadata_path <- shinyAssistantUI:::.claude_tool_metadata_path(map_path)
  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, "edit-retain", "Edit", list(diffStartLine = 5L)
  )
  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      list(list(type = "assistant", message = list(content = list(
        list(type = "tool_use", id = "edit-retain", name = "Edit", input = list())
      ))))
    },
    .delete_claude_session = function(session_id, directory = NULL) stop("delete failed")
  )
  handler <- structure(function(...) NULL,
                       release_session = function(session_id) character())

  expect_false(suppressWarnings(shinyAssistantUI:::.claude_delete_session(
    "session-failure", project = d, handler = handler,
    archived_path = file.path(d, "archived.rds"), session_map_path = map_path
  )))
  expect_identical(
    shinyAssistantUI:::.read_tool_metadata(metadata_path)$`edit-retain`,
    list(diffStartLine = 5L)
  )
})
