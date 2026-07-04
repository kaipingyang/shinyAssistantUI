library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: Gemini ─────────────────────────────────────────────────────────────
# Google Gemini:标志性 Google 蓝(#1a73e8) + 浅蓝强调 + 大圆角。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("Gemini style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

gemini_theme <- assistant_theme(
  primary            = "#1a73e8",
  primary_foreground = "#ffffff",
  background         = "#ffffff",
  foreground         = "#1f1f1f",
  muted              = "#f0f4f9",
  accent             = "#e8f0fe",
  border             = "#dadce0",
  ring               = "#1a73e8",
  radius             = "1.25rem"
)

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, theme = gemini_theme,
    suggestions = list(
      list(prompt = "Plan a weekend trip", text = "Plan a trip"),
      list(prompt = "Explain a concept simply", text = "Explain simply")
    )
  )
}
shinyApp(ui, server)
