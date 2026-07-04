library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)
h <- function(message, on_chunk, on_done, on_artifact, ...) {
  on_chunk("I've drafted a document for you — see the panel on the right. ")
  on_artifact(
    id = "doc-1", title = "Project Plan",
    type = "markdown",
    content = "# Project Plan\n\n- Phase 1: research\n- Phase 2: build\n- Phase 3: ship\n\n**Deadline:** Q3"
  )
  on_done()
}
ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) assistantUIServer("chat", handler = h)
shinyApp(ui, server)
