# Fixture: minimal app with the composer (attachments enabled by default) for
# verifying paste-image + drag-drop-file -> attachment.
library(shiny)
library(shinyAssistantUI)
ui <- assistantUIPage(assistantUIOutput("chat", height = "100vh"), title = "attach")
server <- function(input, output, session) {
  assistantUIServer("chat",
    handler = function(message, on_chunk, on_done, ...) { on_chunk("ok"); on_done() })
}
shinyApp(ui, server)
