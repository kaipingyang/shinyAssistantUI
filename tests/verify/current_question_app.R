# Fixture: scroll-spy 顶部提问条 —— 每条消息回一段很长的答复(撑高滚动区),
# 便于验证"上翻到某轮 → 顶部显示那一轮的提问"。assistantUIPage(无 Bootstrap)。
library(shiny)
library(shinyAssistantUI)

`%||%` <- function(x, y) if (is.null(x)) y else x

handler <- function(message, on_chunk, on_done, ...) {
  filler <- paste(rep("This is a filler line to make each answer tall enough to require scrolling.",
                      30), collapse = "\n\n")
  on_chunk(paste0("Answer to: ", message, "\n\n", filler))
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 560px; height: 440px;", assistantUIOutput("chat", height = "100%"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
