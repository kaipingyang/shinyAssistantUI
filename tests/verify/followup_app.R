# Fixture for Plan 48B (dynamic follow-up suggestions). Echo handler replies GOT[<message>]
# and pushes two follow-up chips via on_suggestions() after streaming — no LLM needed.
suppressMessages({library(shiny); library(shinyAssistantUI)})
ui <- assistantUIPage(assistantUIOutput("chat", height = "100%"), title = "followup")
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, on_suggestions, ...) {
      on_chunk(paste0("GOT[", message, "]"))
      # push next-step chips (any time before on_done); render below the reply
      on_suggestions(list("do A", "do B"))
      on_done()
    }
  )
}
shinyApp(ui, server)
