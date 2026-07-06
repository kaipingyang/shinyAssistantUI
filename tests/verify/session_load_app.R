library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

# 复现 React #31:历史会话里含 file_path 工具(Read/Write)时,会话加载路径
# (.claude_msgs_to_thread)构造的 argsText 曾是 json 类 → 被当对象序列化 → 崩。
handler <- make_claude_handler(
  options = ClaudeAgentOptions(include_partial_messages = TRUE,
                               permission_mode = "bypassPermissions")
)

ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler,
                    on_session_load = make_claude_session_loader(),
                    show_thread_list = TRUE)
}
shinyApp(ui, server)
