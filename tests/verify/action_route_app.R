library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

recv <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("AI_RECEIVED[", message, "]")); on_done()
}
ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = recv,
    commands = list(list(name = "plan", description = "Make a plan (AI)", prompt = "Please make a plan.")),
    action_items = list(
      list(section = "Model", id = "model", label = "Switch model", description = "Switch the active model"),
      list(section = "Settings", id = "clear", label = "Clear history", description = "Clear conversation")
    ),
    on_action = function(id) message(sprintf("[on_action] %s", id))
  )
}
shinyApp(ui, server)
