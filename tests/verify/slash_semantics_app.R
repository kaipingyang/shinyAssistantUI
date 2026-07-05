library(shiny); library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# echo handler:把 R 端实际收到的 message 原样回显,用于探测 slash 语义
# —— 若 /greet 展开为 prompt,handler 收到的是 prompt 文本,而非字面 "/greet"。
echo_received <- function(message, on_chunk, on_done, ...) {
  on_chunk(paste0("RECEIVED[", message, "]"))
  on_done()
}

ui <- page_fluid(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = echo_received,
    commands = list(
      list(name = "greet", description = "Greet the user",
           prompt = "Reply with exactly: HELLO_FROM_PROMPT"),
      list(name = "summarize", description = "Summarize conversation",
           prompt = "Please summarize the conversation.")
    ),
    tools = list(
      list(name = "get_weather", description = "Get weather"),
      list(name = "calculate", description = "Do math")
    )
  )
}
shinyApp(ui, server)
