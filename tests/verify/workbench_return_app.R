# Browser fixture for Workbench return/startup responsiveness. Session discovery
# deliberately blocks for three seconds; the React shell must already be painted.
suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})

project <- file.path(tempdir(), "workbench-return-project")
dir.create(project, recursive = TRUE, showWarnings = FALSE)

slow_sessions <- function(directory, limit = 100L, archived_ids = character()) {
  Sys.sleep(3)
  list(list(
    id = "11111111-1111-1111-1111-111111111111",
    title = "Delayed history",
    preview = "Session discovery completed",
    createdAt = as.numeric(Sys.time()) * 1000
  ))
}

port <- as.integer(Sys.getenv("AUI_PORT", "9922"))
testthat::with_mocked_bindings(
  {
    app <- shinyAssistantUI:::.claude_chat_app(
      project = project,
      options = ClaudeAgentSDK::ClaudeAgentOptions(
        cwd = project,
        permission_mode = "bypassPermissions",
        include_partial_messages = TRUE
      ),
      prewarm = FALSE
    )
    shiny::runApp(app, host = "127.0.0.1", port = port, launch.browser = FALSE)
  },
  list_claude_sessions = slow_sessions,
  .package = "shinyAssistantUI"
)
