library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

echo <- function(message, on_chunk, on_done, ...) { on_chunk("hi"); on_done() }

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, show_thread_list = TRUE,
    on_rename = function(thread_id, title) {
      message(sprintf("[on_rename] thread=%s title=%s", thread_id, title))
    }
  )
}
shinyApp(ui, server)
