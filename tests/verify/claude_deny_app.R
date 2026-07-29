# Deny 测试 fixture:permission_mode="default" 使工具触发审批卡。
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
readRenviron(file.path(PROJ, ".Renviron"))
app <- shinyAssistantUI:::.claude_chat_app(
  PROJ, prewarm = FALSE,
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd                         = PROJ,
    permission_mode             = "default",
    permission_prompt_tool_name = "stdio",
    settings                    = '{"permissions":{"ask":["*"]}}',
    include_partial_messages    = TRUE
  )
)
shiny::runApp(app, host = "127.0.0.1", port = as.integer(Sys.getenv("AUI_PORT", "9472")),
              launch.browser = FALSE)
