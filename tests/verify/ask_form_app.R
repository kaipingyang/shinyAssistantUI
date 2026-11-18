# Plan 166 browser fixture: AskUserForm over A2UI with the addin's real wiring.
# A fake "Claude turn" keeps the run active while the verifier drives the real
# AskUserForm MCP subprocess against this app's form endpoint.
suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})
`%||%` <- function(x, y) if (is.null(x)) y else x

form_url <- Sys.getenv("AUI_FORM_URL")
thread_file <- Sys.getenv("AUI_THREAD_FILE")
done_flag <- Sys.getenv("AUI_DONE_FLAG")
stopifnot(nzchar(form_url), nzchar(thread_file), nzchar(done_flag))

emitters <- shinyAssistantUI:::.new_ask_form_emitters()
service <- shinyAssistantUI:::.new_ask_form_service(emitters)
endpoint <- shinyAssistantUI:::.start_run_r_review_server(form_url, service)
stopifnot(!is.null(endpoint))
onStop(function() endpoint$close())

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "92vh")
)

server <- function(input, output, session) {
  owner <- paste0("session-", sample.int(1e9, 1))
  shinyAssistantUI:::.bind_ask_form(service, session, "chat_input", owner)
  handler <- function(message, thread_id, run_id, on_a2ui, on_chunk, on_done,
                      register_cancel = NULL, ...) {
    writeLines(c(thread_id, run_id), thread_file)
    release <- emitters$register(thread_id, run_id, on_a2ui, owner = owner)
    on_chunk("Let me ask you a few things.")
    promises::promise(function(resolve, reject) {
      settled <- FALSE
      finish <- function() {
        if (settled) return(invisible(NULL))
        settled <<- TRUE
        release()
        on_done()
        resolve(NULL)
      }
      if (is.function(register_cancel)) register_cancel(function() later::later(finish, 0.2))
      poll <- function() {
        if (settled) return(invisible(NULL))
        if (file.exists(done_flag)) {
          unlink(done_flag)
          finish()
        } else later::later(poll, 0.1)
      }
      later::later(poll, 0.1)
    })
  }
  assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    a2ui_action_handler = function(name, context, thread_id, surface_id, on_a2ui, on_error) {
      service$handle_action(name, context, thread_id, surface_id, on_error, on_a2ui, owner = owner)
    }
  )
}

shinyApp(ui, server)
