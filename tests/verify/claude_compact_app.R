suppressMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})
try(readRenviron("~/.Renviron"), silent = TRUE)

handler <- make_claude_handler(
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd = tempdir(),
    permission_mode = "bypassPermissions",
    include_partial_messages = TRUE
  ),
  session_map_path = tempfile(fileext = ".rds")
)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Claude compact verification"
)
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = handler,
    persistence = "client",
    action_items = shinyAssistantUI:::.claude_action_items()
  )
}
shinyApp(ui, server)
