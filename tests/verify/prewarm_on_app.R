library(shiny)

verify_lib <- Sys.getenv(
  "SHINYASSISTANT_VERIFY_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
library(shinyAssistantUI, lib.loc = verify_lib)
library(ClaudeAgentSDK, lib.loc = verify_lib)

# Use an empty synthetic workspace: initialization is real, but no project or
# session content is submitted or printed by this verification fixture.
verify_workspace <- file.path(tempdir(), "shinyassistant-prewarm-verify")
dir.create(verify_workspace, recursive = TRUE, showWarnings = FALSE)
handler <- make_claude_handler(
  options = ClaudeAgentOptions(
    cwd = verify_workspace,
    include_partial_messages = TRUE,
    permission_mode = "bypassPermissions"
  ),
  session_map_path = file.path(verify_workspace, "session-map.rds")
)

ui <- fluidPage(
  tags$head(
    tags$meta(
      name = "shinyassistant-verify-package",
      content = paste0("installed-", as.character(packageVersion("shinyAssistantUI")))
    ),
    tags$link(rel = "icon", href = "data:,")
  ),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  session_handler <- handler
  real_warmup <- attr(session_handler, "warmup")
  attr(session_handler, "warmup") <- function(thread_id, project = NULL) {
    cat("VERIFY_PREWARM_WRAPPER_START\n")
    session$sendCustomMessage("verify:prewarm-start", list(marker = "synthetic"))
    started <- proc.time()[["elapsed"]]
    real_warmup(thread_id, project)
    initialize_ms <- (proc.time()[["elapsed"]] - started) * 1000

    # A second lookup must reuse the connected client. This does not submit a
    # prompt; it verifies that the first user message will not own cold connect.
    cached_started <- proc.time()[["elapsed"]]
    real_warmup(thread_id, project)
    cached_ms <- (proc.time()[["elapsed"]] - cached_started) * 1000
    session$sendCustomMessage("verify:prewarm-done", list(
      marker = "synthetic",
      initialize_ms = initialize_ms,
      cached_ms = cached_ms
    ))
    cat(sprintf(
      "VERIFY_PREWARM_WRAPPER_DONE initialize_ms=%.0f cached_ms=%.1f\n",
      initialize_ms,
      cached_ms
    ))
    invisible(NULL)
  }

  assistantUIServer(
    "chat",
    handler = session_handler,
    prewarm = TRUE,
    warming_label = "Starting Claude Code\u2026"
  )
}

shinyApp(ui, server)
