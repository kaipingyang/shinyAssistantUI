# Real Claude fixture for acknowledged model switching. Verification prompts use
# synthetic markers only; no project/session content is requested or printed.
suppressMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})
try(readRenviron("~/.Renviron"), silent = TRUE)

map_path <- Sys.getenv("MODEL_SWITCH_ACK_MAP", tempfile(fileext = ".rds"))
handler <- make_claude_handler(
  options = ClaudeAgentSDK::ClaudeAgentOptions(
    cwd = tempdir(),
    permission_mode = "bypassPermissions",
    include_partial_messages = TRUE
  ),
  session_map_path = map_path
)

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "100vh"),
  title = "model switch acknowledgement verification"
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
