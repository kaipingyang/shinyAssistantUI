library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

# 验证 #2 子agent进度卡 + #7 stop_task:用 bypassPermissions,让 Task 子agent自动跑,
# on_task 自动接线(make_claude_handler 的回调),UI 渲染 [data-slot=aui_task_card] + Stop 按钮。
handler <- make_claude_handler(
  options = ClaudeAgentOptions(
    include_partial_messages = TRUE,
    permission_mode          = "bypassPermissions"
  )
)

ui <- fluidPage(
  assistantUIOutput("chat", height = "90vh")
)

server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}

shinyApp(ui, server)
