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
    action_items = list(
      list(
        section = "Model",
        id = "thinking-on",
        label = "Enable thinking",
        description = "Turn on extended thinking mode"
      ),
      list(
        section = "Model",
        id = "thinking-off",
        label = "Disable thinking",
        description = "Turn off extended thinking mode"
      ),
      list(
        section = "Settings",
        id = "clear-history",
        label = "Clear history",
        description = "Clear all stored conversations"
      )
    ),
    on_action = function(id) {
      if (id == "clear-history") {
        session$sendCustomMessage(paste0("chat_input:clear"), list())
      }
    },
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
