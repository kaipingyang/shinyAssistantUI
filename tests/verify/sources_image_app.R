library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# 1x1 透明 PNG data URL
PNG <- "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

h <- function(message, on_chunk, on_done, on_source, on_image, ...) {
  on_chunk("Here is the answer with a citation and an image. ")
  on_source("https://example.com/paper", title = "Reference Paper")
  on_source("https://en.wikipedia.org/wiki/AI", title = "Wikipedia: AI")
  on_image(PNG)
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) assistantUIServer("chat", handler = h)
shinyApp(ui, server)
