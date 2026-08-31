library(shiny)
library(shinyAssistantUI)

cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")

state_dir <- tempfile("edit-diff-line-browser-")
dir.create(state_dir)
map_path <- file.path(state_dir, "session_map.rds")
metadata_path <- shinyAssistantUI:::.claude_tool_metadata_path(map_path)
target <- file.path(state_dir, "edit_line_target.R")
writeLines(c(
  "# line 1",
  "# line 2",
  "# line 3",
  "target <- old",
  "# line 5"
), target)

tool_id <- "edit-line-stable-1"
raw_history <- list(
  list(type = "assistant", uuid = "history-assistant", message = list(content = list(
    list(
      type = "tool_use", id = tool_id, name = "Edit",
      input = list(
        file_path = target,
        old_string = "target <- old",
        new_string = "target <- new"
      )
    )
  ))),
  list(type = "user", uuid = "history-result", message = list(content = list(
    list(
      type = "tool_result", tool_use_id = tool_id,
      content = "FILE_MUTATED_OLD_ABSENT", is_error = FALSE
    )
  )))
)

edit_args <- list(
  file_path = target,
  old_string = "target <- old",
  new_string = "target <- new"
)
original_content <- paste(c(
  "# line 1",
  "# line 2",
  "# line 3",
  "target <- old",
  "# line 5"
), collapse = "\n")

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  # Auto-edit race: CLI has already changed the file before R consumes the
  # canonical tool call, so disk enrichment cannot find old_string.
  writeLines(c(
    "# line 1",
    "# line 2",
    "# line 3",
    "target <- new",
    "# line 5"
  ), target)
  on_tool_call(tool_id, "Edit", edit_args)

  # Yield to Shiny so Chromium can verify that the initial card has no fake
  # line-1 gutter. Then mimic the real Claude UserMessage result recovery.
  later::later(function() {
    recovery <- shinyAssistantUI:::.claude_edit_result_recovery(
      list(
        filePath = target,
        oldString = edit_args$old_string,
        newString = edit_args$new_string,
        originalFile = original_content,
        replaceAll = FALSE
      ),
      edit_args
    )
    if (!is.null(recovery)) {
      on_tool_call(
        tool_id, "Edit", recovery$args,
        annotations = list(diffStartLine = recovery$diffStartLine)
      )
    }
    old_absent <- !any(readLines(target, warn = FALSE) == "target <- old")
    on_tool_result(
      tool_id,
      if (old_absent) "FILE_MUTATED_OLD_ABSENT" else "FILE_MUTATION_FAILED",
      is_error = !old_absent
    )
    on_chunk("LIVE_EDIT_COMPLETE")
    on_done()
  }, delay = 1.5)
}
attr(handler, "record_tool_metadata") <- function(
    tool_call_id, tool_name, annotations, thread_id = NULL, project = NULL) {
  shinyAssistantUI:::.record_tool_metadata(
    metadata_path, tool_call_id, tool_name, annotations
  )
}

history_loader <- function(session_id, thread_id, send_thread, ...) {
  messages <- shinyAssistantUI:::.claude_msgs_to_thread(
    raw_history,
    metadata = shinyAssistantUI:::.read_tool_metadata(metadata_path)
  )
  send_thread(messages)
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Edit diff line stability"
)
server <- function(input, output, session) {
  controls <- assistantUIServer(
    "chat", handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    on_session_load = history_loader,
    working_dir = state_dir,
    prewarm = FALSE
  )
  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(list(
      id = "history-edit-line",
      title = "History Edit Line",
      preview = "Restored Edit diff",
      createdAt = "2026-01-01T00:00:00Z"
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
