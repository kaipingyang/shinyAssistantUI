# Fixture：验证 @mention 工作区搜索（优化后：内存 memo + 向量化搜索 + JS 防抖）仍正常。
library(shiny)
library(bslib)
library(shinyAssistantUI)

proj <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
handler <- function(message, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }
ws <- shinyAssistantUI:::.make_addin_workspace_search_provider(proj)

ui <- page_fluid(
  tags$style(HTML("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }")),
  div(style = "width: 640px;", assistantUIOutput("chat", height = "88vh"))
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, workspace_search_provider = ws)
}
shinyApp(ui, server)
