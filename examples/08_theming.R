library(shiny)
library(bslib)
library(shinyAssistantUI)

# ── Theme customization 示例 ──────────────────────────────────────────────────
# 演示 assistant_theme() + dark_mode。三个 widget 各用不同主题,展示 per-widget
# scoped CSS 变量注入(互不干扰)。

echo_handler <- function(message, on_chunk, on_done, ...) {
  for (w in strsplit(paste("You said:", message), " ")[[1]]) {
    on_chunk(paste0(w, " ")); Sys.sleep(0.03)
  }
  on_done()
}

ui <- page_navbar(
  title = "shinyAssistantUI — Theming",
  nav_panel(
    "Brand blue",
    card(full_screen = TRUE, assistantUIOutput("chat_blue", height = "80vh"))
  ),
  nav_panel(
    "Warm / rounded",
    card(full_screen = TRUE, assistantUIOutput("chat_warm", height = "80vh"))
  ),
  nav_panel(
    "Dark mode",
    card(full_screen = TRUE, assistantUIOutput("chat_dark", height = "80vh"))
  )
)

server <- function(input, output, session) {
  # 品牌蓝:主色 + 浅蓝背景
  assistantUIServer(
    "chat_blue", handler = echo_handler,
    theme = assistant_theme(
      primary            = "#2563eb",
      primary_foreground = "#ffffff",
      background         = "#f8fafc",
      accent             = "#dbeafe"
    )
  )

  # 暖色 + 大圆角(radius 走原样透传)
  assistantUIServer(
    "chat_warm", handler = echo_handler,
    theme = assistant_theme(
      primary = "tomato",
      accent  = "#fde68a",
      border  = "#fca5a5",
      radius  = "1.25rem"
    )
  )

  # 暗色模式:dark_mode = TRUE(或 "auto" 跟随系统)
  assistantUIServer(
    "chat_dark", handler = echo_handler,
    dark_mode = TRUE,
    theme     = assistant_theme(primary = "#22d3ee")  # 暗色下叠加自定义主色
  )
}

shinyApp(ui, server)
