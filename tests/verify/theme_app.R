library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

h <- function(message, on_chunk, on_done, ...) { on_chunk("hi there"); on_done() }

ui <- page_fluid(
  div(assistantUIOutput("chat_light", height = "45vh")),
  div(assistantUIOutput("chat_dark",  height = "45vh"))
)

server <- function(input, output, session) {
  # 自定义浅色主题:蓝色主色 + 浅蓝背景 + 大圆角
  assistantUIServer(
    "chat_light", handler = h,
    theme = assistant_theme(primary = "#2563eb", background = "#eff6ff", radius = "1rem")
  )
  # 暗色模式(无自定义色,走内置 .dark 调色板)
  assistantUIServer("chat_dark", handler = h, dark_mode = TRUE)
}

shinyApp(ui, server)
