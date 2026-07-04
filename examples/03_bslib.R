library(shiny)
library(bslib)
devtools::load_all(here::here())

# ── 方案 A：使用 ellmer 连接 Azure Databricks / OpenAI 兼容接口 ───────────────
# handler <- ellmer_stream_handler(function() {
#   ellmer::chat_openai_compatible(
#     base_url    = "https://your-endpoint/serving-endpoints/v1",
#     model       = "your-model-name",
#     credentials = function() Sys.getenv("DATABRICKS_TOKEN")
#   )
# })

# ── 方案 B：简单模拟（不依赖 ellmer）────────────────────────────────────────
handler <- function(message, thread_id, on_chunk, on_done, on_error) {
  words <- strsplit(paste0("你说的是（线程 ", thread_id, "）：", message, "。这是模拟流式回复。"), " ")[[1]]
  for (w in words) {
    on_chunk(paste0(w, " "))
    Sys.sleep(0.05)
  }
  on_done()
}

ui <- page_sidebar(
  title = "Assistant UI",
  sidebar = sidebar(
    title = "设置",
    width = 250,
    p("使用左侧线程列表切换对话（需开启 show_thread_list）", class = "text-muted small"),
    hr(),
    actionButton("clear", "新建对话", icon = icon("plus"), class = "btn-outline-primary w-100")
  ),
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
  chat <- assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE   # 在 widget 内显示线程历史列表
  )

  observeEvent(input$clear, chat$clear())
}

shinyApp(ui, server)
