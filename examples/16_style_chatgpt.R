library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── Style: ChatGPT ────────────────────────────────────────────────────────────
# 近白背景 + OpenAI 标志性青绿主色(#10a37f) + 浅灰用户气泡。

echo <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("ChatGPT style.", message), " ")[[1]]) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }
  on_done()
}

chatgpt_theme <- assistant_theme(
  primary            = "#10a37f",
  primary_foreground = "#ffffff",
  background         = "#ffffff",
  foreground         = "#0d0d0d",
  muted              = "#f7f7f8",
  accent             = "#f7f7f8",
  border             = "#e5e5e5",
  radius             = "0.75rem"
)

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo, theme = chatgpt_theme,
    suggestions = list(
      list(prompt = "Explain quantum computing", text = "Explain quantum computing"),
      list(prompt = "Write a haiku about the sea", text = "Write a haiku")
    )
  )
}
shinyApp(ui, server)
