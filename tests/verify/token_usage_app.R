# Fixture:验证 token 用量环(Plan 33)。环用 context_tokens(当前占用),show_usage=TRUE。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, on_usage = NULL, ...) {
  on_chunk("hello\n")
  if (!is.null(on_usage)) on_usage(tokens = 50000L, context_tokens = 50000L)  # 50k / 200k = 25%
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "80vh"))
)
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = handler,
    show_usage = TRUE, context_window = 200000L, usage_style = "ring"
  )
}
shinyApp(ui, server)
