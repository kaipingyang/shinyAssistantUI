library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)
echo <- function(message, on_chunk, on_done, ...) { on_chunk("reply text"); on_done() }
ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = echo, show_timestamps = TRUE)
}
shinyApp(ui, server)
