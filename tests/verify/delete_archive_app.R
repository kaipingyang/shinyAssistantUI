suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

# 内存会话状态（模拟 addin 的 server 权威 + archive/delete 重推），不依赖真实 SDK。
sessions_env <- new.env(parent = emptyenv())
sessions_env$active <- c("sess-keep", "sess-arch", "sess-del")
sessions_env$archived <- character(0)
sessions_env$deleted <- character(0)

build_sessions <- function() {
  ids <- setdiff(c(sessions_env$active, sessions_env$archived), sessions_env$deleted)
  lapply(ids, function(id) list(
    id = id, title = id, preview = id,
    createdAt = "2026-07-01T00:00:00Z",
    archived = id %in% sessions_env$archived
  ))
}

handler <- function(message, thread_id, on_chunk, on_done, ...) {
  # 助手回一段含 R 代码块的 markdown，用于验证语法高亮。
  on_chunk("Here is R code:\n\n```r\nx <- 1\nprint(x)\n```\n")
  on_done()
}

ui <- fluidPage(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  tags$script(HTML(paste0(
    "Shiny.addCustomMessageHandler('deleted_probe', function(p){",
    "var el=document.getElementById('deleted-probe'); if(el){el.textContent=p||'';}});"
  ))),
  tags$div(id = "deleted-probe", style = "position:fixed;bottom:0;left:0;opacity:0;", ""),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  push <- function() ctrl$send_sessions(list(sessions = build_sessions()))
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    on_archive_session = function(session_id, archived) {
      if (isTRUE(archived)) {
        sessions_env$archived <- union(sessions_env$archived, session_id)
        sessions_env$active <- setdiff(sessions_env$active, session_id)
      } else {
        sessions_env$archived <- setdiff(sessions_env$archived, session_id)
        sessions_env$active <- union(sessions_env$active, session_id)
      }
      push()
    },
    on_delete_session = function(session_id) {
      sessions_env$deleted <- union(sessions_env$deleted, session_id)
      session$sendCustomMessage("deleted_probe", session_id)
      push()
    }
  )
  session$onFlushed(function() push(), once = TRUE)
}

shinyApp(ui, server)
