# Claude-backed edit test:验证 make_claude_handler 下 编辑用户气泡→Update 会重新触发 Claude(4b)。
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
readRenviron(file.path(PROJ, ".Renviron"))
app <- shinyAssistantUI:::.claude_chat_app(
  PROJ, prewarm = FALSE,
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd                         = PROJ,
    permission_mode             = "bypassPermissions",
    permission_prompt_tool_name = "stdio",
    include_partial_messages    = TRUE
  )
)
shiny::runApp(app, host = "127.0.0.1", port = as.integer(Sys.getenv("AUI_PORT", "9405")),
              launch.browser = FALSE)
