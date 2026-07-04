library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: Grok ───────────────────────────────────────────────────────────────
# xAI 极简暗色高对比:近黑背景 + 白主色。dark_mode=TRUE 让未覆盖 token 也走暗色。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("Grok style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

grok_theme <- assistant_theme(
  background         = "#0a0a0a",
  foreground         = "#f5f5f5",
  primary            = "#ffffff",
  primary_foreground = "#0a0a0a",
  card               = "#141414",
  muted              = "#1a1a1a",
  accent             = "#1f1f1f",
  border             = "#2a2a2a",
  input              = "#2a2a2a",
  radius             = "0.5rem"
)

ui <- page_fluid(
  tags$head(tags$style("body{background:#0a0a0a;}")),
  assistantUIOutput("chat", height = "100vh")
)
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, theme = grok_theme, dark_mode = TRUE,
    suggestions = list(list(prompt = "What's happening in tech today?", text = "Tech news"))
  )
}
shinyApp(ui, server)
