# Fixture: the addin's real backend (make_claude_handler + claude CLI) to reproduce
# image-send behavior. Loads home + project .Renviron for CLI creds.
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
try(readRenviron("~/.Renviron"), silent = TRUE)
try(readRenviron("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI/.Renviron"), silent = TRUE)
handler <- make_claude_handler(options = ClaudeAgentSDK::ClaudeAgentOptions(
  cwd                      = tempdir(),
  permission_mode          = "bypassPermissions",
  include_partial_messages = TRUE))
ui <- assistantUIPage(assistantUIOutput("chat", height = "100vh"), title = "claude backend")
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
