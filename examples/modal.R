library(shiny)
library(bslib)
library(ellmer)
devtools::load_all(here::here())

`%||%` <- function(x, y) if (is.null(x)) y else x

# ── 工具定义 ─────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3)
    conditions <- c("Sunny", "Partly Cloudy", "Cloudy", "Light Rain",
                    "Rain", "Windy", "Thunderstorm", "Snow")
    days  <- c("TODAY", "MON", "TUE", "WED", "THU")
    cond  <- sample(conditions, 1)
    temp  <- sample(45:85, 1)
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
        list(day = days[[i]], high = ft + sample(3:7, 1),
             low = ft - sample(3:7, 1), condition = sample(conditions, 1))
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
  arguments   = list(expression = type_string("A valid R expression, e.g. 'sqrt(144)'")),
  annotations = tool_annotations(title = "Calculator", icon = "calculator")
)

# ── Chat 对象池（thread_id → list(chat, current)）────────────────────────────
chats <- list()

get_chat <- function(thread_id) {
  if (!is.null(chats[[thread_id]])) return(chats[[thread_id]])

  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  chat$register_tools(list(get_weather, calculate))

  current <- new.env(parent = emptyenv())
  current$on_tool_call   <- NULL
  current$on_tool_result <- NULL

  chat$on_tool_request(coro::async(function(request) {
    current$on_tool_call(
      tool_call_id = request@id,
      tool_name    = request@name,
      args         = request@arguments,
      annotations  = request@tool@annotations %||% list()
    )
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

# ── Handler ───────────────────────────────────────────────────────────────────
handler <- coro::async(function(
  message, thread_id, attachments,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, is_cancelled,
  wait_for_approval, register_cancel
) {
  obj     <- get_chat(thread_id)
  chat    <- obj$chat
  current <- obj$current

  current$on_tool_call   <- on_tool_call
  current$on_tool_result <- on_tool_result

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

  current$on_tool_call   <- NULL
  current$on_tool_result <- NULL
})

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- page_fluid(
  title = "Modal Assistant Test",
  tags$head(tags$style(HTML("
    /* 悬浮气泡固定在右下角 */
    .modal-wrap {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 9999;
    }
    /* 让气泡按钮本身不被页面 overflow:hidden 裁剪 */
    .bslib-page-fill, .html-widget-output { overflow: visible !important; }
  "))),

  h2("Modal Assistant — Test Page"),
  p(
    "The AI assistant floats in the bottom-right corner.",
    "Click the", tags$strong("bot icon"), "to open/close the chat panel."
  ),

  layout_columns(
    col_widths = c(6, 6),

    card(
      card_header("Test Checklist"),
      tags$ul(
        tags$li("Bot icon visible at bottom-right"),
        tags$li("Click icon → panel opens (400 × 580 px)"),
        tags$li("Click icon again → panel closes"),
        tags$li("Panel auto-opens when AI responds (unstable_openOnRunStart)"),
        tags$li("Starter suggestions appear on welcome screen"),
        tags$li("Type a message → streaming response"),
        tags$li("Ask for weather → tool card + weather widget"),
        tags$li("Ask to calculate → tool card with result"),
        tags$li("Stop button cancels in-flight request"),
        tags$li("Panel stays open during streaming"),
        tags$li("Scroll page → panel stays fixed in corner"),
        tags$li("Resize browser → panel repositions correctly")
      )
    ),

    card(
      card_header("Suggested Test Prompts"),
      tags$p(tags$strong("Basic:")),
      tags$ul(
        tags$li("\"Hello, what can you help me with?\""),
        tags$li("\"Write a haiku about coding\"")
      ),
      tags$p(tags$strong("Tools:")),
      tags$ul(
        tags$li("\"What's the weather in Tokyo?\""),
        tags$li("\"Calculate the square root of 1764\""),
        tags$li("\"Weather in Paris and calculate 15% of 480\"")
      ),
      tags$p(tags$strong("Edge cases:")),
      tags$ul(
        tags$li("\"Write a very long essay\" then click Stop"),
        tags$li("Open panel, close it, open again — state preserved?")
      )
    )
  ),

  # ── 填充页面，测试滚动时气泡固定 ─────────────────────────────────────────
  card(
    card_header("Long Page Content (scroll test)"),
    lapply(1:8, function(i) {
      p(paste0("Paragraph ", i, ": ",
               paste(sample(c(
                 "Shiny", "ellmer", "tool calling", "streaming",
                 "React", "assistant", "modal", "floating", "widget"
               ), 12, replace = TRUE), collapse = " "), "."))
    })
  ),

  # ── 悬浮气泡 ──────────────────────────────────────────────────────────────
  div(
    class = "modal-wrap",
    assistantUIOutput("modal_chat", modal = TRUE)
  )
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "modal_chat",
    handler = handler,
    modal   = TRUE,
    tools   = list(
      list(name = "get_weather", description = "Get current weather for a city"),
      list(name = "calculate",   description = "Evaluate a mathematical expression")
    ),
    suggestions = list(
      list(prompt = "What's the weather in San Francisco?",
           text   = "SF weather"),
      list(prompt = "Calculate the result of 12^2 + 5^2",
           text   = "Calculate 12² + 5²"),
      list(prompt = "Hello! What can you help me with?",
           text   = "Say hello")
    ),
    on_feedback = function(message_id, type) {
      message("[FEEDBACK] ", type, " on message=", message_id)
    }
  )
}

shinyApp(ui, server)
