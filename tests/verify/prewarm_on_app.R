library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

# prewarm=TRUE:挂载即后台连接初始线程 → 首条消息不冷启动。
handler <- make_claude_handler(
  options = ClaudeAgentOptions(include_partial_messages = TRUE,
                               permission_mode = "bypassPermissions")
)
ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, prewarm = TRUE)
}
shinyApp(ui, server)
