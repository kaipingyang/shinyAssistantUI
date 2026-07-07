library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

# 对照:prewarm=FALSE → 不预热 → 首条消息仍走冷启动(显示指示器)。
handler <- make_claude_handler(
  options = ClaudeAgentOptions(include_partial_messages = TRUE,
                               permission_mode = "bypassPermissions")
)
ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, prewarm = FALSE)
}
shinyApp(ui, server)
