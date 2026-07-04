library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# ── 消息队列示例 ──────────────────────────────────────────────────────────────
# AI 回复期间(慢流式),composer 会在 Stop 按钮旁出现一个时钟按钮:
# 输入下一条消息后点它即可排队,当前回复结束后自动发送排队消息。

slow_echo <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("Replying to: ", message, " "))
  for (i in 1:6) { on_chunk(". "); Sys.sleep(0.4) }
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = slow_echo)
}
shinyApp(ui, server)
