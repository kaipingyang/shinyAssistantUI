# Fixture: cwd已经是ERP时，prose中的ERP/file应由后端安全解析到cwd根文件。
library(shiny)
library(shinyAssistantUI)

fixture_root <- "/tmp/aui-openfile-cwd-prefix"
project <- file.path(fixture_root, "ERP")
unlink(fixture_root, recursive = TRUE, force = TRUE)
dir.create(project, recursive = TRUE)
live_name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
history_name <- "\u5386\u53f2_\u4ea4\u63a5.md"
file.create(file.path(project, live_name), file.path(project, history_name))

handler <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("Live handoff: `ERP/", live_name, "`"))
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "76vh")),
  tags$div(id = "resolved-path-probe", textOutput("resolved"))
)

server <- function(input, output, session) {
  resolved <- reactiveVal("none")
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_open_file = function(path, line = NULL) {
      value <- shinyAssistantUI:::.addin_resolve_file_path(path, project)
      resolved(if (is.null(value)) "<NULL>" else value)
    },
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      send_thread(messages = list(
        list(
          id = "prefix-history-user",
          role = "user",
          content = list(list(type = "text", text = "Open historical handoff"))
        ),
        list(
          id = "prefix-history-assistant",
          role = "assistant",
          status = list(type = "complete", reason = "stop"),
          content = list(list(
            type = "text",
            text = paste0("Historical handoff: `ERP/", history_name, "`")
          ))
        )
      ), has_more = FALSE)
    }
  )
  output$resolved <- renderText(resolved())
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(list(
      id = "prefix-history",
      title = "CWD prefix history",
      preview = "Open historical handoff",
      createdAt = as.numeric(Sys.time()) * 1000
    ))))
  }, once = TRUE)
  session$onSessionEnded(function() unlink(fixture_root, recursive = TRUE, force = TRUE))
}

shinyApp(ui, server)
