# Plan 163 browser gate: run_r output review. Uses the installed package's real
# review service, nanonext endpoint and session binding; the verifier drives the
# real run_r MCP stdio subprocess against it.
suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

review_url <- Sys.getenv("AUI_REVIEW_URL")
thread_file <- Sys.getenv("AUI_THREAD_FILE")
review_timeout <- as.numeric(Sys.getenv("AUI_REVIEW_TIMEOUT", "600"))
stopifnot(nzchar(review_url), nzchar(thread_file))

service <- shinyAssistantUI:::.new_run_r_review_service(
  enabled = function() shinyAssistantUI:::.read_run_r_output_review_enabled(),
  timeout = review_timeout
)
endpoint <- shinyAssistantUI:::.start_run_r_review_server(review_url, service)
stopifnot(!is.null(endpoint))
onStop(function() endpoint$close())
bindings <- new.env(parent = emptyenv())

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "92vh")
)

server <- function(input, output, session) {
  key <- paste0("s", as.integer(runif(1, 1, 1e9)))
  # The widget's Shiny input id is "<outputId>_input" (the addin uses "chat_input").
  binding <- shinyAssistantUI:::.bind_run_r_review(
    service, session, "chat_input",
    on_enabled_changed = function(enabled) {
      for (name in ls(bindings)) get(name, envir = bindings)$broadcast_enabled(enabled)
    }
  )
  assign(key, binding, envir = bindings)
  session$onSessionEnded(function() rm(list = key, envir = bindings))

  handler <- function(message, on_chunk, on_done, register_cancel = NULL, thread_id = NULL, ...) {
    writeLines(as.character(thread_id %||% ""), thread_file)
    if (identical(message, "wait")) {
      return(promises::promise(function(resolve, reject) {
        on_chunk("Waiting for the R tool...")
        register_cancel(function() later::later(function() { on_done(); resolve(NULL) }, 0.2))
      }))
    }
    if (identical(message, "code")) {
      on_chunk("Run this:\n\n```r\nprint(\"secret-token\")\nprint(42)\n```\n")
      on_done()
      return(invisible(NULL))
    }
    on_chunk(paste0("echo: ", substr(message, 1, 400)))
    on_done()
    invisible(NULL)
  }
  attr(handler, "ui_addons") <- list(runROutputReview = binding$config)
  assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    on_run_in_console = function(code) shinyAssistantUI:::.addin_run_r_capture(code)
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x
shinyApp(ui, server)
