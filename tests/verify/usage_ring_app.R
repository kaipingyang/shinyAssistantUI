library(shiny); library(shinyAssistantUI)
# 环应显示"当前上下文占用"(context_tokens=305.9k / 1M = 31%),而非累计吞吐 tokens(915.1k=92%)。
handler <- function(message, on_chunk, on_done, on_usage, ...) {
  on_chunk("ok")
  if (is.function(on_usage))
    on_usage(cost_usd = 0.01, tokens = 915100, context_tokens = 305900,
             turns = 3, model = "claude-sonnet-4.6[1m]", context_window = 1000000)
  on_done()
}
ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "80vh")))
server <- function(input, output, session)
  assistantUIServer("chat", handler = handler, show_usage = TRUE, context_window = 200000, usage_style = "ring")
shinyApp(ui, server)
