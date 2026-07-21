# Fixture：思考强度选择器（Settings）。stub handler 暴露 ui_capabilities$thinking + action_handler 记录。
library(shiny)
library(bslib)
library(shinyAssistantUI)

handler <- function(message, thread_id, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }
attr(handler, "ui_capabilities") <- list(
  permission_mode = list(value = "default",
                         options = list(list(value = "default", label = "Manual"))),
  thinking = list(value = "default", options = list(
    list(value = "default",  label = "Default"),
    list(value = "adaptive", label = "Adaptive"),
    list(value = "enabled",  label = "Extended"),
    list(value = "disabled", label = "Off")
  )),
  model = list(value = "default", options = list(
    list(value = "default", label = "Default"),
    list(value = "haiku",   label = "Haiku"),
    list(value = "sonnet",  label = "Sonnet"),
    list(value = "opus",    label = "Opus")
  ))
)

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  assistantUIOutput("chat", height = "92vh"),
  verbatimTextOutput("probe")
)
server <- function(input, output, session) {
  got <- reactiveVal("")
  h <- handler
  attr(h, "action_handler") <- function(id, thread_id, send_action_result = function(...) {}) {
    got(id)
    send_action_result(paste("ok", id), "ok", value = sub("^thinking:", "", id))
  }
  assistantUIServer("chat", handler = h, show_thread_list = TRUE)
  output$probe <- renderText(got())
}
shinyApp(ui, server)
