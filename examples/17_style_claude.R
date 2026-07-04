library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: Claude ─────────────────────────────────────────────────────────────
# Anthropic 暖色系:奶油背景 + 陶土/赭石主色(#d97757) + 暖灰文字。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("Claude style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

claude_theme <- assistant_theme(
  primary            = "#d97757",
  primary_foreground = "#ffffff",
  background         = "#f0eee6",
  foreground         = "#3d3d3a",
  card               = "#faf9f5",
  muted              = "#e8e5d8",
  accent             = "#e8e5d8",
  border             = "#dad7cc",
  radius             = "0.9rem"
)

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, theme = claude_theme,
    suggestions = list(
      list(prompt = "Help me draft an email", text = "Draft an email"),
      list(prompt = "Summarize this article", text = "Summarize an article")
    )
  )
}
shinyApp(ui, server)
