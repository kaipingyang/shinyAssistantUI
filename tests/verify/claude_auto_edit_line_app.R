suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
})

package_project <- Sys.getenv("AUI_PACKAGE_PROJECT")
edit_project <- Sys.getenv("AUI_EDIT_PROJECT")
stopifnot(nzchar(package_project), nzchar(edit_project), dir.exists(edit_project))
readRenviron(file.path(package_project, ".Renviron"))
cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")
cat("edit_project=", edit_project, "\n", sep = "")

permission_mode <- Sys.getenv("AUI_PERMISSION_MODE", "bypassPermissions")
valid_modes <- c("default", "acceptEdits", "bypassPermissions", "yolo")
stopifnot(permission_mode %in% valid_modes)

option_args <- list(
  cwd = edit_project,
  permission_mode = if (identical(permission_mode, "yolo")) {
    "bypassPermissions"
  } else {
    permission_mode
  },
  permission_prompt_tool_name = "stdio",
  include_partial_messages = TRUE
)
if (identical(permission_mode, "default")) {
  option_args$settings <- '{"permissions":{"ask":["Edit"]}}'
}
claude_options <- do.call(ClaudeAgentSDK::ClaudeAgentOptions, option_args)
# YOLO is a shinyAssistantUI pseudo-mode. make_claude_handler maps it to
# bypassPermissions while dropping the permission-prompt channel entirely.
if (identical(permission_mode, "yolo")) {
  claude_options$permission_mode <- "yolo"
}
cat("permission_mode=", permission_mode, "\n", sep = "")

app <- shinyAssistantUI:::.claude_chat_app(
  edit_project,
  prewarm = FALSE,
  options = claude_options
)

shiny::runApp(
  app,
  host = "127.0.0.1",
  port = as.integer(Sys.getenv("AUI_PORT", "9631")),
  launch.browser = FALSE
)
