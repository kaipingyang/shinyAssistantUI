library(shiny)
devtools::load_all(here::here())

# ── handler（可替换为 ellmer_stream_handler）───────────────────────────────
handler <- function(message, thread_id, on_chunk, on_done, on_error) {
  words <- strsplit(
    paste0("你说的是（线程 ", thread_id, "）：", message, "。这是模拟流式回复。"),
    " "
  )[[1]]
  for (w in words) {
    on_chunk(paste0(w, " "))
    Sys.sleep(0.05)
  }
  on_done()
}

# ── UI：无任何框架，widget 直接撑满全视口 ──────────────────────────────────
ui <- tagList(
  tags$head(
    tags$style(HTML("
      html, body {
        height: 100%;
        margin: 0;
        padding: 0;
        overflow: hidden;
      }
    "))
  ),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE
  )
}

shinyApp(ui, server)
