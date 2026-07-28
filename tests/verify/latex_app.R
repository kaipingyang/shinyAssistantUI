# Fixture:验证 LaTeX 数学(Plan 34,latex=TRUE)。handler 回带行内 + 块级公式。
library(shiny)
library(shinyAssistantUI)

handler <- function(message, on_chunk, on_done, ...) {
  on_chunk("Inline math $E = mc^2$ and a block:\n\n$$\n\\hat{\\beta} = (X^{T}X)^{-1}X^{T}y\n$$\n")
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 660px;", assistantUIOutput("chat", height = "80vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, latex = TRUE)
}
shinyApp(ui, server)
