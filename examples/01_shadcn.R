library(shiny)
library(ellmer)
devtools::load_all(here::here())

# ── 配置（从 .Renviron 读取，参见 .Renviron.example）────────────────────────
# OPENAI_BASE_URL=https://<your-endpoint>/serving-endpoints
# OPENAI_MODEL=<your-model>
# OPENAI_API_KEY=<your-token>

# ── ellmer chat（每个线程独立 Chat 对象，保留多轮上下文）─────────────────────
chats <- list()

get_chat <- function(thread_id) {
  if (is.null(chats[[thread_id]])) {
    chats[[thread_id]] <<- chat_openai_compatible(
      base_url    = Sys.getenv("OPENAI_BASE_URL"),
      model       = Sys.getenv("OPENAI_MODEL"),
      credentials = function() Sys.getenv("OPENAI_API_KEY")
    )
  }
  chats[[thread_id]]
}

# ── handler：异步流式，返回 promise ──────────────────────────────────────────
# stream_async() 返回 async generator，必须用 coro::await_each() 迭代
handler <- coro::async(function(message, thread_id, on_chunk, on_done, on_error) {
  chat <- get_chat(thread_id)
  stream <- chat$stream_async(message)
  for (chunk in coro::await_each(stream)) {
    on_chunk(chunk)
  }
  on_done()
})

# ── UI：无任何框架，widget 直接撑满全视口 ──────────────────────────────────
ui <- tagList(
  tags$head(
    tags$style(HTML("
      html, body {
        height: 100%;
        margin: 0;
        padding: 0;
        overflow: hidden;
      }
    "))
  ),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE
  )
}

shinyApp(ui, server)
