library(shiny)
library(ClaudeAgentSDK)
library(shinyAssistantUI)

# 测试用:permission_mode 由环境变量控制,验证"连接时模式"是否抑制审批。
mode <- Sys.getenv("AUI_TEST_MODE", "default")
handler <- make_claude_handler(
  options = ClaudeAgentOptions(
    permission_mode = mode,
    permission_prompt_tool_name = "stdio",
    include_partial_messages = TRUE
  )
)
ui <- tagList(
  tags$head(tags$style(HTML("html,body{height:100%;margin:0}"))),
  assistantUIOutput("chat", height = "100vh")
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler,
    tools = list(list(name = "Bash", description = "Execute shell commands")))
}
shinyApp(ui, server)
