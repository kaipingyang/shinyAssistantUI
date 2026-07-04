library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: Perplexity ─────────────────────────────────────────────────────────
# Perplexity:石油/青碧主色(#20808d) + 米白背景 + 深墨文字。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("Perplexity style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

perplexity_theme <- assistant_theme(
  primary            = "#20808d",
  primary_foreground = "#ffffff",
  background         = "#fcfcf9",
  foreground         = "#091717",
  card               = "#ffffff",
  muted              = "#f0f2f0",
  accent             = "#e3f2f2",
  border             = "#d9dcd9",
  ring               = "#20808d",
  radius             = "0.6rem"
)

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, theme = perplexity_theme,
    suggestions = list(
      list(prompt = "What is the latest in AI research?", text = "Latest AI research"),
      list(prompt = "Compare two frameworks", text = "Compare frameworks")
    )
  )
}
shinyApp(ui, server)
