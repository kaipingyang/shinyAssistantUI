library(shiny)
library(ellmer)
devtools::load_all(here::here())

# ── 工具定义 ─────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3)
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

# ── Handler ───────────────────────────────────────────────────────────────────
handler <- make_ellmer_handler(
  chat = function() chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  ),
  tools          = list(get_weather, calculate),
  approval_tools = c("calculate")
)

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML(
    "html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }"
  ))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE,
    on_feedback      = function(message_id, type) {
      message("[FEEDBACK] ", type, " on message=", message_id)
    },
    suggestions = list(
      list(prompt = "What's the weather in San Francisco?",
           text   = "What's the weather in SF?"),
      list(prompt = "Calculate the result of 2^10 / 4",
           text   = "Calculate 2^10 / 4")
    ),
    commands = list(
      list(name = "summarize", description = "Summarize the conversation",
           prompt = "Please summarize our conversation so far in a few sentences."),
      list(name = "translate",  description = "Translate text to another language",
           prompt = "Please translate the above text to English."),
      list(name = "help",       description = "List available commands",
           prompt = "What tools and commands are available? Please list them.")
    ),
    tools = list(
      list(name = "get_weather", description = "Get current weather for a city"),
      list(name = "calculate",   description = "Evaluate a mathematical expression")
    )
  )
}

shinyApp(ui, server)
