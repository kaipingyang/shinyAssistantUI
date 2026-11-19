# Plugin acceptance fixture: the REAL Claude Code addin app (.claude_chat_app with
# make_claude_handler, run_r + review, AskUserForm, UI-first prompt) loaded only from
# the library in AUI_LIB. The R console server runs in this process, standing in for
# the RStudio main session, so run_r executes here.
lib <- Sys.getenv("AUI_LIB")
stopifnot(nzchar(lib), dir.exists(lib))
.libPaths(c(lib, .Library))
suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
stopifnot(identical(normalizePath(find.package("shinyAssistantUI")), normalizePath(file.path(lib, "shinyAssistantUI"))))
cat("PLUGIN_LIB ", lib, " sau=", as.character(packageVersion("shinyAssistantUI")),
    " sdk=", as.character(packageVersion("ClaudeAgentSDK")), "\n", sep = "")
# Credentials come from the real ~/.Renviron; HOME is a throwaway directory so the
# addin starts from default settings and never rewrites the user's ~/.claude_addin.
try(readRenviron(Sys.getenv("AUI_RENVIRON")), silent = TRUE)
Sys.setenv(HOME = Sys.getenv("AUI_HOME"))
stopifnot(!file.exists(file.path(Sys.getenv("HOME"), ".claude_addin", "addin_settings.json")))
proj <- Sys.getenv("AUI_PROJECT")
dir.create(proj, showWarnings = FALSE, recursive = TRUE)
console_url <- shinyAssistantUI:::.addin_ensure_r_console_server(envir = globalenv(), echo = FALSE)
stopifnot(!is.null(console_url))
app <- shinyAssistantUI:::.claude_chat_app(project = proj, console_url = console_url, prewarm = FALSE)
shiny::runApp(app, host = "127.0.0.1", port = as.integer(Sys.getenv("AUI_PORT")), launch.browser = FALSE)
