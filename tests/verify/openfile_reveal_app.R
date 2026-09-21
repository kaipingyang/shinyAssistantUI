suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

fixture_root <- Sys.getenv("AUI_HOST_FIXTURE_ROOT")
stopifnot(nzchar(fixture_root), dir.exists(fixture_root))
fixture_project <- normalizePath(file.path(fixture_root, "ERP"))
live_name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
history_name <- "\u5386\u53f2_\u4ea4\u63a5.md"

ui <- bslib::page_fluid(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  bslib::layout_columns(
    col_widths = c(8, 4),
    assistantUIOutput("chat", height = "92vh"),
    div(
      assistantUIOutput("other", height = "44vh"),
      assistantUIOutput("plain", height = "44vh")
    )
  ),
  div(style = "display:none", textOutput("host_probe"))
)

server <- function(input, output, session) {
  empty_probe <- function() list(
    opened = list(), console = list(), edits = list(), messages = list(), loads = list()
  )
  probe <- reactiveVal(list(chat = empty_probe(), other = empty_probe(), plain = empty_probe()))
  record <- function(id, field, value) {
    state <- isolate(probe())
    state[[id]][[field]] <- append(state[[id]][[field]], list(value))
    probe(state)
  }
  output$host_probe <- renderText(as.character(jsonlite::toJSON(
    probe(), auto_unbox = TRUE, null = "null"
  )))
  outputOptions(output, "host_probe", suspendWhenHidden = FALSE)

  make_handler <- function(id) {
    force(id)
    function(message, thread_id, on_chunk, on_done,
             on_tool_call = NULL, on_tool_result = NULL, ...) {
      record(id, "messages", list(text = message, thread = thread_id))
      if (startsWith(message, "I ran this in my R console:")) {
        on_chunk(paste0("Console feedback received by ", id, "."))
      } else if (id == "chat") {
        for (tool in list(
          list(id = "read", name = "Read", path = "R/server.R", error = FALSE),
          list(id = "edit", name = "Edit", path = "R/handlers.R", error = FALSE),
          list(id = "write", name = "Write", path = "R/addin.R", error = FALSE),
          list(id = "failed", name = "Edit", path = "R/not-written.R", error = TRUE)
        )) {
          on_tool_call(paste0("host-", tool$id), tool$name, list(file_path = tool$path))
          on_tool_result(
            paste0("host-", tool$id),
            if (tool$error) "Synthetic edit failed" else "Synthetic tool succeeded",
            is_error = tool$error
          )
        }
        on_chunk(paste0(
          "Edited files: `addin.R`. Explicit line: `R/app.R:12`.\n\n",
          "Unicode handoff: `ERP/", live_name, "`.\n\n",
          "```r\nprint(42L)\n```\n\n",
          "```Rscript\nstop(\"SYNTHETIC_HOST_ERROR\")\n```\n\n",
          "```python\nprint(42)\n```\n\n",
          "```\nplain unlabeled block\n```\n\nHOST_REPLY_COMPLETE"
        ))
      } else {
        on_chunk(paste0(
          id, " code:\n\n```r\nprint(21L)\n```\n\n",
          "```python\nprint(21)\n```\n\n", toupper(id), "_REPLY_COMPLETE"
        ))
      }
      on_done()
    }
  }
  console_callback <- function(id) {
    force(id)
    function(code, thread_id = NULL, project = NULL) {
      record(id, "console", list(code = code, thread = thread_id, project = project))
      if (grepl("SYNTHETIC_HOST_ERROR", code, fixed = TRUE)) {
        stop("SYNTHETIC_HOST_ERROR", call. = FALSE)
      }
      list(ok = TRUE, output = paste0("SYNTHETIC_", toupper(id), "_RESULT_42"), error = "")
    }
  }

  controls <- assistantUIServer(
    "chat", handler = make_handler("chat"),
    show_thread_list = TRUE, persistence = "server",
    workspace_mode = TRUE, working_dir = fixture_project,
    ide_context_provider = function() list(path = "/synthetic/demo.R", rel = "R/demo.R"),
    on_open_file = function(path, line = NULL, thread_id = NULL, project = NULL) {
      resolved <- path
      if (startsWith(path, "ERP/")) {
        resolved <- shinyAssistantUI:::.addin_resolve_file_path(path, fixture_project)
      }
      record("chat", "opened", list(
        path = path, resolved = resolved, line = line, thread = thread_id, project = project
      ))
    },
    on_edits = function(edits, thread_id = NULL, project = NULL) {
      record("chat", "edits", list(
        paths = lapply(edits, function(edit) edit$path), thread = thread_id, project = project
      ))
      invisible(NULL)
    },
    on_run_in_console = console_callback("chat"),
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      record("chat", "loads", list(session = session_id, thread = thread_id))
      label <- if (session_id == "open-hist-a") "A" else "B"
      full_path <- paste0("/synthetic/history-", tolower(label), "/dm.R")
      args <- if (label == "A") list(file_path = full_path) else list(path = full_path)
      send_thread(messages = list(
        list(id = paste0("hist-u-", label), role = "user",
             content = list(list(type = "text", text = paste("Open historical", label)))),
        list(
          id = paste0("hist-a-", label), role = "assistant",
          status = list(type = "complete", reason = "stop"),
          content = list(
            list(
              type = "tool-call", toolCallId = paste0("hist-tool-", label),
              toolName = "Read", args = args,
              argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
              result = "Historical read succeeded", isError = FALSE
            ),
            list(type = "text", text = paste0(
              "Historical ", label, ": `dm.R:19`.\n\n",
              "Historical handoff: `ERP/", history_name, "`.\n\n",
              "```r\nprint(\"HISTORY_", label, "\")\n```\n\nHISTORY_", label, "_COMPLETE"
            ))
          )
        )
      ), has_more = FALSE)
    }
  )
  assistantUIServer(
    "other", make_handler("other"), persistence = "none",
    working_dir = fixture_project, on_run_in_console = console_callback("other")
  )
  assistantUIServer("plain", make_handler("plain"), persistence = "none")
  session$onFlushed(function() {
    controls$send_sessions(list(sessions = lapply(c("a", "b"), function(id) list(
      id = paste0("open-hist-", id), title = paste("Open history", toupper(id)),
      project = fixture_project
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
