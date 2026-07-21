# RStudio addin — UI shell & client-side action items
# 从 addin.R 拆出（Plan 16 Phase 2，行为不变）。

# Addin 专用全屏 UI：fillPage 建立 html/body 的 100% 高度链，但不加载
# Bootstrap，避免其全局样式覆盖 widget 内的 Tailwind/shadcn 组件。
.claude_chat_ui <- function() {
  assistantUIPage(
    assistantUIOutput("chat", height = "100%")
  )
}

# 客户端本地动作项（不发给 AI）：上下文用量 / compact / 清空 / MCP 状态。
.claude_action_items <- function() {
  list(
    list(section = "Context", id = "context", command = "context",
         label = "Context usage", description = "Show current context-window usage"),
    list(section = "Context", id = "compact", command = "compact",
         label = "Compact conversation", description = "Summarize this conversation to free context"),
    list(section = "Context", id = "clear", command = "clear",
         label = "New conversation", description = "Clear this conversation and start fresh"),
    list(section = "Customize", id = "mcp", command = "mcp",
         label = "MCP status", description = "Show connected MCP servers"),
    list(section = "Customize", id = "model", command = "model",
         label = "Switch model", description = "Choose which model answers your prompts")
  )
}
