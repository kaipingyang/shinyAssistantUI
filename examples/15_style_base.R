library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: Base ───────────────────────────────────────────────────────────────
# assistant-ui 默认 shadcn 中性风格(不加任何 theme,展示原生外观)。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("Base style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo,
    suggestions = list(list(prompt = "What can you do?", text = "What can you do?"))
  )
}
shinyApp(ui, server)
