library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

project <- Sys.getenv("PLAN67_REAL_PROJECT")
map_path <- Sys.getenv("PLAN67_REAL_MAP")
phase <- Sys.getenv("PLAN67_REAL_PHASE", "setup")
info_path <- Sys.getenv("PLAN67_REAL_INFO")

options <- ClaudeAgentSDK::ClaudeAgentOptions(
  cwd = project,
  permission_mode = "bypassPermissions",
  permission_prompt_tool_name = "stdio",
  include_partial_messages = TRUE
)
handler <- make_claude_handler(options = options, session_map_path = map_path)
loader <- make_claude_session_loader(map_path)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Plan 67 real Claude smoke"
)
server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    persistence = "server", on_session_load = loader,
    max_concurrent_runs = 2L, prewarm = FALSE,
    show_usage = TRUE, context_window = 200000L
  )
  if (identical(phase, "history")) {
    info <- readRDS(info_path)
    session$onFlushed(function() {
      ctrl$send_sessions(list(sessions = list(
        list(id = info[[1L]], title = "Real Alpha", preview = "PLAN67_SETUP_A", createdAt = "2026-08-13T00:00:00Z"),
        list(id = info[[2L]], title = "Real Beta", preview = "PLAN67_SETUP_B", createdAt = "2026-08-13T00:00:01Z")
      )))
    }, once = TRUE)
  }
}
shinyApp(ui, server)
