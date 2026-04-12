library(shiny)
library(bslib)
devtools::load_all(here::here())

ui <- page_sidebar(
  title = "Assistant UI",
  sidebar = sidebar(
    title = "设置",
    width = 250,
    p("在这里放侧边栏控件", class = "text-muted small"),
    hr(),
    actionButton("clear", "清空对话", icon = icon("trash"), class = "btn-outline-secondary w-100")
  ),
  # 主区域：chat 撑满剩余高度
  card(
    full_screen = TRUE,
    height = "100%",
    card_body(
      padding = 0,
      assistantUIOutput("chat", height = "100%")
    )
  )
)

server <- function(input, output, session) {
  chat <- assistantUIServer("chat", handler = function(message, on_chunk, on_done, on_error) {
    words <- strsplit(paste("你说的是：", message, "。这是模拟流式回复。"), " ")[[1]]
    for (w in words) {
      on_chunk(paste0(w, " "))
      Sys.sleep(0.05)
    }
    on_done()
  })

  observeEvent(input$clear, chat$clear())
}

shinyApp(ui, server)
