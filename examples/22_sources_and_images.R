library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── 引用来源 + 原生图像 part 示例 ─────────────────────────────────────────────
# on_source(url, title) 在回答里加可点击来源脚注(RAG 场景)。
# on_image(data_url_or_url) 在 assistant 消息里直接渲染图像。

PNG_DOT <- "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

handler <- function(message, on_chunk, on_done, on_source, on_image, ...) {
  on_chunk("Based on the sources below, the answer is 42. ")
  on_source("https://en.wikipedia.org/wiki/42", title = "Wikipedia: 42")
  on_source("https://example.com/hitchhikers", title = "The Hitchhiker's Guide")
  on_image(PNG_DOT)
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = handler,
    suggestions = list(list(prompt = "What is the answer to everything?", text = "The ultimate answer"))
  )
}
shinyApp(ui, server)
