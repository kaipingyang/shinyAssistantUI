# Fixture:验证 agent 共享状态(Plan 36)。handler 调 on_state(list(progress,...))。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_state = NULL, ...) {
  if (!is.null(on_state)) {
    on_state(list(progress = 0.5, current = "bgplot.R", status = "analyzing"))
  }
  on_chunk("working...\n")
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "80vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
