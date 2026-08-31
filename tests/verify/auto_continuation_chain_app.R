library(shiny)
library(shinyAssistantUI)

calls <- reactiveVal(character())
handler <- function(message, on_chunk, on_done, on_thinking,
                    on_auto_continue, continuation_kind = NULL, ...) {
  kind <- if (is.null(continuation_kind) || !nzchar(continuation_kind)) {
    "ordinary"
  } else {
    continuation_kind
  }
  seen <- c(isolate(calls()), paste0(kind, "::", message))
  calls(seen)
  index <- length(seen)
  if (index == 1L) {
    on_thinking("The tool finished; I should provide a final response.")
    on_auto_continue(
      notice = paste0(
        "Claude completed the tool call but did not produce a final response. ",
        "Continuing automatically\u2026"
      ),
      prompt = paste0(
        "Please continue from the completed tool results and provide the final response. ",
        "Do not repeat completed tool calls."
      ),
      kind = "tool-postlude"
    )
    on_done()
  } else if (index == 2L) {
    on_thinking("I have the answer but still have not stated it visibly.")
    on_auto_continue(
      notice = paste0(
        "Claude finished thinking but did not produce a user-visible response. ",
        "Continuing automatically\u2026"
      ),
      prompt = paste0(
        "Please provide the final user-visible response now. ",
        "Do not continue with reasoning only."
      ),
      kind = "generic"
    )
    on_done()
  } else if (index == 3L) {
    on_thinking("The generic recovery still did not state the answer visibly.")
    on_auto_continue(
      notice = paste0(
        "Claude still did not produce a user-visible response. ",
        "Retrying once with a minimal continuation\u2026"
      ),
      prompt = "继续",
      kind = "minimal"
    )
    on_done()
  } else {
    on_chunk("CHAIN_COMPLETE")
    on_done()
  }
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "75vh"),
  verbatimTextOutput("calls")
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
  output$calls <- renderText(paste(calls(), collapse = "\n---\n"))
}
shinyApp(ui, server)
