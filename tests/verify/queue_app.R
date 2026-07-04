library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)
# 慢流式:约 3s,留出排队时间窗
h <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("echo:", message, " "))
  for (i in 1:7) { on_chunk(". "); Sys.sleep(0.4) }
  on_done()
}
ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) assistantUIServer("chat", handler = h)
shinyApp(ui, server)
