# Repro:编辑用户气泡 → Update 是否重新触发 handler(4b)。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("echo: ", message))
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "80vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
