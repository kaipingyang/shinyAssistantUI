# addin 验证 app:用 .claude_chat_app + 假编辑器上下文(含唯一 token 的选区),
# 验证 (1) 渲染 (2) system_prompt append 注入的上下文真的到达 Claude(无需工具即可复述)。
suppressMessages({ library(shiny); library(shinyAssistantUI) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
ctx <- list(
  path       = file.path(PROJ, "R", "ZebraQuokka.R"),
  rel        = "R/ZebraQuokka.R",
  selection  = "ZebraQuokka42 <- function() 'unique-marker-9x'",
  first_line = 10L, last_line = 10L
)
app <- shinyAssistantUI:::.claude_chat_app(
  PROJ, ctx = ctx, prewarm = FALSE,
  # 用真实的 .addin_context_text 构造 append,但用 bypassPermissions 隔离审批变量,
  # 专测"上下文是否到达 Claude"。
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd                         = PROJ,
    system_prompt               = ClaudeAgentSDK::SystemPromptPreset(
      append = shinyAssistantUI:::.addin_context_text(ctx, PROJ)),
    permission_mode             = "bypassPermissions",
    permission_prompt_tool_name = "stdio",
    include_partial_messages    = TRUE
  )
)
shiny::runApp(app, host = "127.0.0.1", port = as.integer(Sys.getenv("AUI_PORT", "9170")),
              launch.browser = FALSE)
