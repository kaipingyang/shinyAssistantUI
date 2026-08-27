home_library <- Sys.getenv(
  "PLAN91_HOME_LIBRARY",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
project <- Sys.getenv("PLAN91_PROJECT", getwd())
session_map <- Sys.getenv(
  "PLAN91_SESSION_MAP",
  tempfile("plan91-real-cron-map-", fileext = ".rds")
)
.libPaths(c(home_library, .libPaths()))

suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})

handler <- make_claude_handler(
  options = ClaudeAgentOptions(
    include_partial_messages = TRUE,
    permission_mode = "bypassPermissions",
    cwd = project
  ),
  session_map_path = session_map
)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "Plan 91 real Cron smoke"
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "client"
  )
}

shinyApp(ui, server)
