library(shiny)
library(shinyAssistantUI)

# 验证 :commands 热更新(切换工作目录后重载 skills 的机制)。swap 按钮模拟"切目录重载"。
handler <- function(message, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }
ui <- tagList(
  assistantUIPage(div(style = "height:90vh", assistantUIOutput("chat", height = "80vh"))),
  actionButton("swap", "swap")
)
server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat", handler = handler,
    commands = list(list(name = "alphacmd", description = "Alpha skill", prompt = "do alpha"))
  )
  observeEvent(input$swap, {
    ctrl$send_commands(list(list(name = "betacmd", description = "Beta skill", prompt = "do beta")))
  })
}
shinyApp(ui, server)
