# Spike (Plan 51 A):真实 codeagent 后端(make_codeagent_handler)跑在 assistantUIServer 的
# ExtendedTask 里 —— 证明嵌套 async 稳、流式回调转发通。真 LLM(OpenAI-compatible,项目 .Renviron)。
library(shiny)
library(shinyAssistantUI)
library(ellmer)
library(codeagent)
readRenviron(".Renviron")

client_factory <- function() {
  chat <- ellmer::chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  # harness-only client:不注册 codeagent 的编码 tool(register_tools = FALSE)。
  codeagent::codeagent_client(chat = chat, register_tools = FALSE, permission_mode = "default")
}

handler <- make_codeagent_handler(client_factory)

ui <- assistantUIPage(div(style = "height:100vh", assistantUIOutput("chat", height = "90vh")))
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
