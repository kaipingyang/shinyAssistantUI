# Fixture:验证 "Strict"(askAll)权限模式出现在选择器且可选中往返。
# 用 make_claude_handler()(离线,不真连 CLI):ui_capabilities/action_handler 自动接线。
library(shiny)
library(shinyAssistantUI)

handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "86vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
