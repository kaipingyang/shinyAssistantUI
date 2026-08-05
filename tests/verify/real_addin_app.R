# Fixture: launch the REAL addin app (.claude_chat_app -> make_claude_handler + full
# addin wiring) headlessly, to reproduce the "silent, no cold-start" report.
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
try(readRenviron("~/.Renviron"), silent = TRUE)
proj <- file.path(tempdir(), "addin-proj"); dir.create(proj, showWarnings = FALSE, recursive = TRUE)
app <- shinyAssistantUI:::.claude_chat_app(project = proj)
shiny::runApp(app, host = "127.0.0.1",
              port = as.integer(Sys.getenv("SAU_PORT", "9920")),
              launch.browser = FALSE)
