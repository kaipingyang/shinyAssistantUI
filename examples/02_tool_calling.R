library(shiny)
library(ellmer)
devtools::load_all(here::here())

# ── 工具定义 ─────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3) # 模拟网络延迟
    list(
      city        = city,
      temperature = sample(c("18°C", "22°C", "28°C", "35°C"), 1),
      condition   = sample(c("Sunny", "Cloudy", "Rainy", "Windy"), 1),
      humidity    = paste0(sample(50:90, 1), "%")
    )
  },
  name        = "get_weather",
  description = "Get current weather information for a city",
  arguments   = list(city = type_string("The name of the city")),
  annotations = tool_annotations(title = "Weather Lookup", icon = "cloud-sun")
)

calculate <- tool(
  function(expression) {
    tryCatch(
      as.character(eval(parse(text = expression))),
      error = function(e) stop(conditionMessage(e))
    )
  },
  name        = "calculate",
  description = "Evaluate a mathematical expression (R syntax)",
  arguments   = list(
    expression = type_string(
      "A valid R expression, e.g. 'sqrt(144)' or '2^10 / 4'"
    )
  ),
  annotations = tool_annotations(title = "Calculator", icon = "calculator")
)

# ── 每线程独立 Chat 对象 ──────────────────────────────────────────────────────
# on_tool_request / on_tool_result 是累加回调，只注册一次。
# 用 environment 做可变引用，每次 handler 调用时更新。
chats <- list()

get_chat <- function(thread_id) {
  if (!is.null(chats[[thread_id]])) return(chats[[thread_id]])

  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  chat$register_tools(list(get_weather, calculate))

  # current 是当次 handler 注入的回调，handler 结束后清空
  current <- new.env(parent = emptyenv())
  current$on_tool_call   <- NULL
  current$on_tool_result <- NULL

  chat$on_tool_request(function(request) {
    current$on_tool_call(
      tool_call_id = request@id,
      tool_name    = request@name,
      args         = request@arguments,
      annotations  = request@tool@annotations
    )
  })

  chat$on_tool_result(function(result) {
    current$on_tool_result(
      tool_call_id = result@request@id,
      result       = if (!is.null(result@error)) result@error else result@value,
      is_error     = !is.null(result@error)
    )
  })

  obj <- list(chat = chat, current = current)
  chats[[thread_id]] <<- obj
  obj
}

# ── handler ──────────────────────────────────────────────────────────────────
handler <- coro::async(function(
  message, thread_id,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result
) {
  obj     <- get_chat(thread_id)
  chat    <- obj$chat
  current <- obj$current

  # 注入本次回调
  current$on_tool_call   <- on_tool_call
  current$on_tool_result <- on_tool_result

  stream <- chat$stream_async(message)
  for (chunk in coro::await_each(stream)) on_chunk(chunk)
  on_done()

  # 清理，避免泄漏到下次调用
  current$on_tool_call   <- NULL
  current$on_tool_result <- NULL
})

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML("
    html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }
  "))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE
  )
}

shinyApp(ui, server)
