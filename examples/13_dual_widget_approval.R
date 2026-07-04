# 双 widget 审批隔离测试
# 目的：验证多 widget 同页时工具审批不串台（HIGH bug 修复）。
# 修复前：模块级 _toolApprovalHandler 单例，后挂载 widget 覆盖前者 →
#   widget A 的审批发到 widget B 的 inputId → A 永久死锁。
# 修复后：Map<inputId, handler> + R 端 annotations 注入 inputId 路由。
#
# 手动验证步骤：
# 1. 两个 chat 并排，各自发一个触发工具的消息（如 "用 bash 列出文件"）
# 2. 两个 chat 各自弹出 Approve/Deny 审批卡
# 3. 分别点击各自的 Approve —— 每个都应正常继续执行（不卡死、不串台）
# 4. 关键：先点左边 Approve，左边工具应执行；再点右边，右边也执行
#    修复前会出现某一侧点击后永久转圈（审批发错了 widget）

library(shiny)
library(bslib)
library(ClaudeAgentSDK)
devtools::load_all(here::here())

# 每个 widget 独立 handler 实例（独立 session_map，避免互相干扰）
make_opts <- function() {
  ClaudeAgentSDK::ClaudeAgentOptions(
    permission_mode             = "default",   # 触发工具审批
    permission_prompt_tool_name = "stdio",
    include_partial_messages    = TRUE
  )
}

handler_a <- make_claude_handler(
  options          = make_opts(),
  session_map_path = file.path(here::here(), ".claude_session_map_dual_a.rds")
)
handler_b <- make_claude_handler(
  options          = make_opts(),
  session_map_path = file.path(here::here(), ".claude_session_map_dual_b.rds")
)

tools_list <- list(
  list(name = "Bash", description = "Execute shell commands"),
  list(name = "Read", description = "Read file contents"),
  list(name = "LS",   description = "List directory contents")
)

suggestions_list <- list(
  list(prompt = "List the files in the current directory using bash", text = "List files"),
  list(prompt = "Show the current date using bash",                   text = "Show date")
)

ui <- page_fluid(
  h3("双 widget 审批隔离测试 — 两侧各自审批应互不干扰"),
  layout_columns(
    col_widths = c(6, 6),
    card(
      card_header("Chat A"),
      assistantUIOutput("chat_a", height = "80vh")
    ),
    card(
      card_header("Chat B"),
      assistantUIOutput("chat_b", height = "80vh")
    )
  )
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat_a",
    handler     = handler_a,
    tools       = tools_list,
    suggestions = suggestions_list
  )
  assistantUIServer(
    "chat_b",
    handler     = handler_b,
    tools       = tools_list,
    suggestions = suggestions_list
  )
}

shinyApp(ui, server)
