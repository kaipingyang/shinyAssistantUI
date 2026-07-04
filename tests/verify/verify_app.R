library(shiny)
library(bslib)
devtools::load_all(here::here(), quiet = TRUE)

# 确定性 handler：不调真实 AI，按固定序列触发所有特性用于端到端验证。
# 用 ... 捕获全部回调（server.R 按 names(formals) 过滤；含 ... 时注入全部）。
verify_handler <- function(message, on_chunk, on_done, on_thinking,
                           on_tool_call, on_tool_result, ...) {
  # 1) thinking / reasoning 卡片
  on_thinking("Analyzing the request and planning sub-agent delegation.")
  Sys.sleep(0.05)

  # 2) 顶层编排工具（sub-agent 父节点，depth 0）
  on_tool_call(
    "parent-1", "research_agent",
    args        = list(topic = "climate"),
    annotations = list(title = "Research Agent", icon = "wrench")
  )
  # 3) 两个子工具调用，parentToolCallId 指向 parent-1（depth 1，缩进嵌套）
  on_tool_call(
    "child-1", "web_search",
    args        = list(query = "climate data 2024"),
    annotations = list(title = "web_search", parentToolCallId = "parent-1")
  )
  on_tool_result("child-1", "Found 12 results", is_error = FALSE)

  on_tool_call(
    "child-2", "summarize",
    args        = list(text = "raw findings"),
    annotations = list(title = "summarize", parentToolCallId = "parent-1")
  )
  on_tool_result("child-2", "Summary complete", is_error = FALSE)

  # 4) 孙工具调用（depth 2）——验证多级
  on_tool_call(
    "grand-1", "fetch_url",
    args        = list(url = "https://example.com"),
    annotations = list(title = "fetch_url", parentToolCallId = "child-2")
  )
  on_tool_result("grand-1", "200 OK", is_error = FALSE)

  on_tool_result("parent-1", "Research complete", is_error = FALSE)

  # 5) 流式文本
  words <- strsplit("Here is the final streamed answer for verification purposes .", " ")[[1]]
  for (w in words) { on_chunk(paste0(w, " ")); Sys.sleep(0.02) }

  # 6) 完成 + followup 建议
  on_done(suggestions = list(
    list(prompt = "Tell me more about climate data"),
    list(prompt = "What are the sources?")
  ))
}

ui <- page_fluid(
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = verify_handler,
    show_thread_list = TRUE,
    suggestions = list(
      list(prompt = "Start a research task", text = "Research climate")
    ),
    commands = list(
      list(name = "help", description = "List commands", prompt = "List commands")
    ),
    tools = list(
      list(name = "research_agent", description = "Delegate to a research sub-agent")
    )
  )
}

shinyApp(ui, server)
