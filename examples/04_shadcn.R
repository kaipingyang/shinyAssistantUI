library(shiny)
library(ellmer)
devtools::load_all(here::here())

# ── 配置（从 .Renviron 读取，参见 .Renviron.example）────────────────────────
# OPENAI_BASE_URL=https://<your-endpoint>/serving-endpoints
# OPENAI_MODEL=<your-model>
# OPENAI_API_KEY=<your-token>

handler <- make_ellmer_handler(
  chat = function() chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
)

ui <- tagList(
  tags$head(tags$style(HTML(
    "html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }"
  ))),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler, show_thread_list = TRUE)
}

shinyApp(ui, server)
