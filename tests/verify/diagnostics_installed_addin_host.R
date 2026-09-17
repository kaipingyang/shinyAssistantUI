suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

project <- Sys.getenv("SAU_ADDIN_PROJECT", "")
stopifnot(dir.exists(project))

expected_package <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
installed <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
stopifnot(identical(installed, expected_package))
cat("installed=", installed, "\n", sep = "")
cat("fixture=installed-addin-host\n")
cat("launch=default-on-no-override\n")

# No mocked package bindings, synthetic ui_addons, persisted override, env
# override, or explicit diagnostics argument. The addin's normal default-on
# settings capture constructs the app-wide service and diagnosticsLaunch truth.
shinyAssistantUI:::.claude_chat_app(
  project = project,
  prewarm = FALSE,
  memory_guard_config = list(enabled = FALSE)
)
