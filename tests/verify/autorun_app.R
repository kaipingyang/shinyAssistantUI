library(shiny)
library(bslib)
library(shinyAssistantUI)
`%||%` <- function(x, y) if (is.null(x)) y else x

handler <- function(message, on_chunk, on_done, ...) { on_chunk("hi"); on_done() }

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  div(style = "width: 760px;", assistantUIOutput("chat", height = "80vh")),
  verbatimTextOutput("autorun")
)

server <- function(input, output, session) {
  autorun <- reactiveVal("")
  assistantUIServer(
    "chat", handler = handler,
    show_thread_list  = TRUE,
    working_dir       = "/proj/app",   # 让 WorkingDirBar 渲染
    auto_run          = FALSE,         # 角度B:暴露 Auto-run 开关(初始关)
    on_toggle_auto_run = function(v) autorun(paste0("toggled:", isTRUE(v)))
  )
  output$autorun <- renderText(autorun())
}
shinyApp(ui, server)
