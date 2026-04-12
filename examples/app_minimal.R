library(shiny)
devtools::load_all(here::here())

ui <- fluidPage(
  tags$h3("shinyAssistantUI — 最小示例"),
  assistantUIOutput("chat", height = "80vh")
)

server <- function(input, output, session) {
  assistantUIServer("chat", handler = function(message, on_chunk, on_done, on_error) {
    # 模拟流式响应
    words <- strsplit(paste("你说的是：", message, "。这是一个模拟回复，用于测试流式输出是否正常工作。"), " ")[[1]]
    for (w in words) {
      on_chunk(paste0(w, " "))
      Sys.sleep(0.05)
    }
    on_done()
  })
}

shinyApp(ui, server)
