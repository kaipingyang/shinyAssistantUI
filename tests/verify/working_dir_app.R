# Fixture：工作目录选择器（浏览器路径，native_picker=FALSE → 手输）。
# 切目录 → send_working_dir + 该目录的 sessions（验证 replace）。
library(shiny)
library(bslib)
library(shinyAssistantUI)

handler <- function(message, thread_id, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }

sessions_for <- function(d) {
  if (grepl("dir-B", d, fixed = TRUE))
    list(list(id = "11111111-1111-1111-1111-11110000000B", title = "B session", preview = "", createdAt = NULL))
  else
    list(list(id = "11111111-1111-1111-1111-11110000000A", title = "A session", preview = "", createdAt = NULL))
}

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  assistantUIOutput("chat", height = "100vh")
)
server <- function(input, output, session) {
  dir_state <- new.env(parent = emptyenv())
  dir_state$cwd <- "/tmp/wd/dir-A"
  ctrl <- assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE, persistence = "server",
    working_dir = dir_state$cwd, native_picker = FALSE,
    on_set_working_dir = function(path) {
      if (is.null(path) || !nzchar(path)) return(invisible(NULL))
      dir_state$cwd <- path
      ctrl$send_working_dir(path, list(dir_state$cwd))   # 先发工作目录
      ctrl$send_sessions(list(sessions = sessions_for(path)))  # 再重推该目录 sessions（替换）
    }
  )
  shiny::observe({ ctrl$send_sessions(list(sessions = sessions_for(dir_state$cwd))) })
}
shinyApp(ui, server)
