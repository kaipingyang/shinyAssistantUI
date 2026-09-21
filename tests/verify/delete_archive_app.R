suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(shinyAssistantUI)
})

# 内存会话状态（模拟 addin 的 server 权威 + archive/delete 重推），不依赖真实 SDK。
sessions_env <- new.env(parent = emptyenv())
sessions_env$active <- c("sess-keep", "sess-arch", "sess-del")
sessions_env$archived <- character(0)
sessions_env$deleted <- character(0)
sessions_env$titles <- setNames(sessions_env$active, sessions_env$active)
sessions_env$threads <- new.env(parent = emptyenv())

build_sessions <- function() {
  ids <- setdiff(c(sessions_env$active, sessions_env$archived), sessions_env$deleted)
  lapply(ids, function(id) list(
    id = id, title = unname(sessions_env$titles[[id]]), preview = id,
    createdAt = "2026-07-01T00:00:00Z",
    archived = id %in% sessions_env$archived
  ))
}

handler <- function(message, thread_id, on_chunk, on_done, ...) {
  # 助手回一段含 R 代码块的 markdown，用于验证语法高亮。
  on_chunk("Here is R code:\n\n```r\nx <- 1\nprint(x)\n```\n")
  on_done()
}

ui <- page_fluid(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  tags$script(HTML(paste0(
    "Shiny.addCustomMessageHandler('deleted_probe', function(p){",
    "var el=document.getElementById('deleted-probe'); if(el){el.textContent=p||'';}});",
    "Shiny.addCustomMessageHandler('renamed_probe', function(p){",
    "document.getElementById('renamed-probe').textContent=p;});"
  ))),
  tags$div(id = "deleted-probe", style = "position:fixed;bottom:0;left:0;opacity:0;", ""),
  tags$div(id = "renamed-probe", style = "position:fixed;bottom:0;left:0;opacity:0;", ""),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  push <- function() ctrl$send_sessions(list(sessions = build_sessions()))
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      sessions_env$threads[[thread_id]] <- session_id
      send_thread(list(
        list(id = paste0(session_id, "-user"), role = "user",
             content = list(list(type = "text", text = paste0("HISTORY[", session_id, "]")))),
        list(id = paste0(session_id, "-answer"), role = "assistant",
             content = list(list(type = "text", text = paste0("RESTORED[", session_id, "]"))))
      ))
    },
    on_rename = function(thread_id, title) {
      session_id <- sessions_env$threads[[thread_id]]
      if (is.null(session_id)) stop("Rename requires a loaded synthetic session")
      sessions_env$titles[[session_id]] <- title
      session$sendCustomMessage("renamed_probe", paste(session_id, title, sep = "|"))
      push()
    },
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
