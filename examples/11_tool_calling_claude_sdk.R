library(shiny)
library(ClaudeAgentSDK)
devtools::load_all(here::here())

# ── Handler（一行）──────────────────────────────────────────────────────────
handler <- make_claude_handler()

# ── 动态加载 Claude Code skills ──────────────────────────────────────────────
skills <- load_claude_skills(project_dir = here::here())

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML(
    "html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }"
  ))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    on_session_load = make_claude_session_loader(),
    commands = skills,
    # 客户端动作(经 make_claude_handler 的 action_handler 自动接线到 ClaudeSDKClient
    # 控制操作;不发给 AI)。id 约定:model:<name> / permissions:<mode> / context / clear。
    action_items = list(
      list(section = "Model", id = "model:claude-sonnet-4.6", label = "Use Sonnet 4.6",
           description = "Switch active model to Sonnet"),
      list(section = "Model", id = "model:claude-haiku-4.5", label = "Use Haiku 4.5",
           description = "Switch active model to Haiku (fast)"),
      list(section = "Permissions", id = "permissions:plan", label = "Plan mode",
           description = "Read-only planning, no edits"),
      list(section = "Permissions", id = "permissions:acceptEdits", label = "Auto-accept edits",
           description = "Automatically accept file edits"),
      list(section = "Permissions", id = "permissions:default", label = "Default permissions",
           description = "Ask before each action"),
      list(section = "Context", id = "context", label = "Show context usage",
           description = "Display current token usage"),
      list(section = "Session", id = "clear", label = "Clear conversation",
           description = "Clear context and start fresh")
    ),
    # on_action 省略 —— make_claude_handler 暴露的 action_handler 会被 assistantUIServer
    # 自动接线,把上面的动作分发到 ClaudeSDKClient 的 set_model / set_permission_mode /
    # get_context_usage / clear。
    suggestions = list(
      list(
        prompt = "List the files in the current directory using bash",
        text = "List files"
      ),
      list(prompt = "Show the current git status", text = "Git status"),
      list(
        prompt = "Show the current date and time using bash",
        text = "Show date/time"
      ),
      list(
        prompt = "What tools and capabilities do you have?",
        text = "What can you do?"
      )
    ),
    tools = list(
      list(name = "Bash", description = "Execute shell commands"),
      list(name = "Read", description = "Read file contents"),
      list(name = "Write", description = "Write files"),
      list(name = "Edit", description = "Edit existing files"),
      list(name = "Glob", description = "Find files by pattern"),
      list(name = "Grep", description = "Search in files"),
      list(name = "WebFetch", description = "Fetch content from a URL"),
      list(name = "LS", description = "List directory contents")
    )
  )

  shiny::observe({
    ctrl$send_sessions(list(sessions = list_claude_sessions()))
  })
}

shinyApp(ui, server)
