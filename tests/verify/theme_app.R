library(shiny)
library(bslib)
library(shinyAssistantUI)

h <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("Theme reply: ", message, "\n\n[Theme link](https://example.invalid/theme)"))
  on_done()
}

page <- page_fluid
if (identical(Sys.getenv("AUI_THEME_HOST"), "standalone")) page <- assistantUIPage
ui <- page(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  div(id = "host_theme_background", class = "bg-primary text-white", "Host background"),
  div(id = "host_theme_text", class = "text-primary", "Host text"),
  div(assistantUIOutput("chat_light", height = "30vh")),
  div(assistantUIOutput("chat_dark", height = "30vh")),
  div(assistantUIOutput("chat_auto", height = "30vh"))
)

server <- function(input, output, session) {
  # 自定义浅色主题:蓝色主色 + 浅蓝背景 + 大圆角
  assistantUIServer(
    "chat_light",
    handler = h,
    theme = assistant_theme(primary = "#2563eb", background = "#eff6ff", radius = "1rem")
  )
  # 暗色模式(无自定义色,走内置 .dark 调色板)
  assistantUIServer("chat_dark", handler = h, dark_mode = TRUE)
  assistantUIServer("chat_auto", handler = h, dark_mode = "auto")
}

shinyApp(ui, server)
