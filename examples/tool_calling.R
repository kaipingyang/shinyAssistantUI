library(shiny)
library(ellmer)
devtools::load_all(here::here())

# ── 工具定义 ─────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3) # 模拟网络延迟
    conditions <- c("Sunny", "Partly Cloudy", "Cloudy", "Light Rain",
                    "Rain", "Windy", "Thunderstorm", "Snow")
    days       <- c("TODAY", "MON", "TUE", "WED", "THU")
    cond       <- sample(conditions, 1)
    temp       <- sample(45:85, 1)

    list(
      city        = city,
      temperature = temp,
      unit        = "F",
      condition   = cond,
      high        = temp + sample(4:10, 1),
      low         = temp - sample(4:10, 1),
      humidity    = sample(40:90, 1),
      wind        = sample(5:35, 1),
      forecast    = lapply(seq_along(days), function(i) {
        ft <- temp + sample(-6:6, 1)
        list(
          day       = days[[i]],
          high      = ft + sample(3:7, 1),
          low       = ft - sample(3:7, 1),
          condition = sample(conditions, 1)
        )
      })
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
# calculate 需要审批（任意 R 代码执行前需确认），get_weather 直接放行。
APPROVAL_TOOLS <- c("calculate")

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
  current$on_tool_call      <- NULL
  current$on_tool_result    <- NULL
  current$wait_for_approval <- NULL

  chat$on_tool_request(coro::async(function(request) {
    needs_approval <- request@name %in% APPROVAL_TOOLS
    current$on_tool_call(
      tool_call_id = request@id,
      tool_name    = request@name,
      args         = request@arguments,
      annotations  = c(
        request@tool@annotations %||% list(),
        list(requiresApproval = needs_approval)
      )
    )

    if (needs_approval) {
      approved <- coro::await(current$wait_for_approval(request@id))
      if (!approved) ellmer::tool_reject("User denied the tool call.")
    }
  }))

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
  message, thread_id, attachments,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, is_cancelled,
  wait_for_approval, register_cancel
) {
  obj     <- get_chat(thread_id)
  chat    <- obj$chat
  current <- obj$current

  # 注入本次回调
  current$on_tool_call      <- on_tool_call
  current$on_tool_result    <- on_tool_result
  current$wait_for_approval <- wait_for_approval

  # 构建多模态 content：文字 + 图片附件 + 文本文件附件
  # 支持类型（ellmer 文档确认）：
  #   image  → content_image_url(data_url)  PNG/JPEG/WebP/GIF
  #   text   → 拼入消息体；a$data 已由 JS 包裹为 <attachment name=...>...</attachment>
  atts <- attachments %||% list()

  img_parts <- lapply(
    Filter(function(a) identical(a$type, "image"), atts),
    function(a) content_image_url(a$data)        # data URL 直接可用
  )

  text_sections <- paste(
    vapply(Filter(function(a) identical(a$type, "text"), atts),
           function(a) a$data,                   # 已含 <attachment> 包裹，直接使用
           character(1)),
    collapse = "\n"
  )
  if (nzchar(text_sections)) {
    full_message <- paste0(text_sections, "\n\n", message)
  } else {
    full_message <- message
  }

  # Level 2 取消：stream_controller 在 cancel observer 触发时立即关闭 HTTP 连接。
  # register_cancel 把 ctrl$cancel 注册到 server.R，Stop 信号到达时直接调用。
  # is_cancelled() 作双保险，处理 approval 等待期间的取消路径。
  ctrl <- ellmer::stream_controller()
  register_cancel(function() ctrl$cancel("User interrupted"))

  stream <- do.call(chat$stream_async, c(list(full_message), img_parts, list(controller = ctrl)))
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

  # 清理，避免泄漏到下次调用
  current$on_tool_call      <- NULL
  current$on_tool_result    <- NULL
  current$wait_for_approval <- NULL
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
    show_thread_list = TRUE,

    suggestions = list(
      list(prompt = "What's the weather in San Francisco?",
           text   = "What's the weather in San Francisco?"),
      list(prompt = "Calculate the result of 2^10 / 4",
           text   = "Calculate 2^10 / 4")
    ),

    commands = list(
      list(name        = "summarize",
           description = "Summarize the conversation",
           prompt      = "Please summarize our conversation so far in a few sentences."),
      list(name        = "translate",
           description = "Translate text to another language",
           prompt      = "Please translate the above text to English."),
      list(name        = "help",
           description = "List available commands",
           prompt      = "What tools and commands are available? Please list them.")
    ),

    tools = list(
      list(name = "get_weather", description = "Get current weather for a city"),
      list(name = "calculate",   description = "Evaluate a mathematical expression")
    )
  )
}

shinyApp(ui, server)
