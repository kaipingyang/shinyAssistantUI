library(shiny)
library(shinyAssistantUI)

calls <- reactiveVal(character())
handler <- function(message, on_chunk, on_done, on_thinking,
                    on_auto_continue, ...) {
  seen <- c(isolate(calls()), message)
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
      )
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
      )
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
