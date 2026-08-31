# Fixture: the addin's real backend (make_claude_handler + claude CLI) to reproduce
# image-send behavior. Loads home credentials; verification launchers may preload a
# project-local .Renviron before starting this app.
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
try(readRenviron("~/.Renviron"), silent = TRUE)
handler <- make_claude_handler(options = ClaudeAgentSDK::ClaudeAgentOptions(
  cwd                      = tempdir(),
  permission_mode          = "bypassPermissions",
  include_partial_messages = TRUE))
ui <- assistantUIPage(assistantUIOutput("chat", height = "100vh"), title = "claude backend")
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
