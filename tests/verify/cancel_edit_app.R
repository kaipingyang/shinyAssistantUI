suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  assistantUIOutput("chat", height = "88vh"),
  div(style = "display:none", verbatimTextOutput("received"))
)

server <- function(input, output, session) {
  received <- reactiveVal(character())
  output$received <- renderText(as.character(jsonlite::toJSON(received(), auto_unbox = TRUE)))
  outputOptions(output, "received", suspendWhenHidden = FALSE)

  handler <- function(message, on_chunk, on_done, register_cancel, ...) {
    received(c(isolate(received()), message))
    if (!identical(message, "cancel then edit")) {
      on_chunk(paste0("echo: ", message))
      on_done()
      return(invisible(NULL))
    }

    promises::promise(function(resolve, reject) {
      settled <- FALSE
      finish <- function() {
        if (settled) return(invisible(NULL))
        settled <<- TRUE
        on_done()
        resolve(NULL)
        invisible(NULL)
      }
      on_chunk("partial answer before cancellation")
      register_cancel(function() {
        # Keep a deterministic drain window in which the browser can edit.
        later::later(finish, delay = 2)
      })
    })
  }

  assistantUIServer("chat", handler = handler, persistence = "server")
}

shinyApp(ui, server)
