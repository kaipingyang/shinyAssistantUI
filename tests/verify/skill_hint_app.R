# Fixture: seed a slash command with an argument_hint via assistantUIServer(commands=)
# so the headless verify can check the menu renders "/greet [name]" (Plan A, no backend).
library(shiny)
library(shinyAssistantUI)
ui <- assistantUIPage(assistantUIOutput("chat", height = "100vh"), title = "skill hint")
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, ...) { on_chunk(paste0("GOT[", message, "]")); on_done() },
    commands = list(
      list(name = "greet", description = "Say hi to someone",
           prompt = "/greet", argument_hint = "[name]")
    ))
}
shinyApp(ui, server)
