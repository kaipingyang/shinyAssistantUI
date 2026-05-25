library(shiny)
library(bslib)
library(ellmer)
devtools::load_all(here::here())

# ── Handler ───────────────────────────────────────────────────────────────────
handler <- coro::async(function(
  message, thread_id, attachments,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, is_cancelled,
  wait_for_approval, register_cancel
) {
  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )

  ctrl <- ellmer::stream_controller()
  register_cancel(function() ctrl$cancel("User interrupted"))

  stream <- chat$stream_async(message, controller = ctrl)
  tryCatch(
    for (chunk in coro::await_each(stream)) {
      if (is_cancelled()) break
      on_chunk(chunk)
    },
    error = function(e) {
      if (!is_cancelled()) on_error(conditionMessage(e))
    }
  )

  on_done()
})

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- page_fluid(
  tags$head(tags$style(HTML("
    /* 把 modal 气泡固定到右下角 */
    .modal-anchor-wrap { position: fixed; bottom: 24px; right: 24px; z-index: 9999; }
  "))),
  h1("Modal Assistant Demo"),
  p("This is a regular Shiny page. The AI assistant floats in the bottom-right corner."),
  p("Click the ", tags$strong("bot icon"), " to open / close the chat panel."),
  hr(),
  p(paste(rep("Lorem ipsum dolor sit amet. ", 30), collapse = "")),
  # 悬浮气泡挂在固定定位容器内
  div(
    class = "modal-anchor-wrap",
    assistantUIOutput("modal_chat", modal = TRUE)
  )
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "modal_chat",
    handler = handler,
    modal   = TRUE,
    suggestions = list(
      list(prompt = "Hello! What can you help me with?"),
      list(prompt = "Tell me a fun fact.")
    )
  )
}

shinyApp(ui, server)
