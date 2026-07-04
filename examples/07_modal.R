library(shiny)
library(bslib)
library(ellmer)
devtools::load_all(here::here())

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

# ── Handler ───────────────────────────────────────────────────────────────────
handler <- make_ellmer_handler(
  chat = function() chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  ),
  tools = list(get_weather, calculate)
)

# ── UI ────────────────────────────────────────────────────────────────────────
ui <- page_fluid(
  title = "Modal Assistant Test",
  tags$head(tags$style(HTML("
    .modal-wrap { position: fixed; bottom: 24px; right: 24px; z-index: 9999; }
    .bslib-page-fill, .html-widget-output { overflow: visible !important; }
  "))),

  h2("Modal Assistant — Test Page"),
  p("The AI assistant floats in the bottom-right corner.",
    "Click the", tags$strong("bot icon"), "to open/close the chat panel."),

  layout_columns(
    col_widths = c(6, 6),
    card(
      card_header("Test Checklist"),
      tags$ul(
        tags$li("Bot icon visible at bottom-right"),
        tags$li("Click icon → panel opens (400 × 580 px)"),
        tags$li("Click icon again → panel closes"),
        tags$li("Starter suggestions appear on welcome screen"),
        tags$li("Type a message → streaming response"),
        tags$li("Ask for weather → tool card + weather widget"),
        tags$li("Ask to calculate → tool card with result"),
        tags$li("Stop button cancels in-flight request"),
        tags$li("Scroll page → panel stays fixed in corner")
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
        tags$li("\"Calculate the square root of 1764\"")
      ),
      tags$p(tags$strong("Edge cases:")),
      tags$ul(
        tags$li("\"Write a very long essay\" then click Stop"),
        tags$li("Open panel, close it, open again — state preserved?")
      )
    )
  ),

  card(
    card_header("Long Page Content (scroll test)"),
    lapply(1:8, function(i) {
      p(paste0("Paragraph ", i, ": ",
               paste(sample(c("Shiny", "ellmer", "tool calling", "streaming",
                              "React", "assistant", "modal", "floating", "widget"),
                            12, replace = TRUE), collapse = " "), "."))
    })
  ),

  div(class = "modal-wrap", assistantUIOutput("modal_chat", modal = TRUE))
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "modal_chat",
    handler     = handler,
    modal       = TRUE,
    tools       = list(
      list(name = "get_weather", description = "Get current weather for a city"),
      list(name = "calculate",   description = "Evaluate a mathematical expression")
    ),
    suggestions = list(
      list(prompt = "What's the weather in San Francisco?", text = "SF weather"),
      list(prompt = "Calculate the result of 12^2 + 5^2",  text = "Calculate 12² + 5²"),
      list(prompt = "Hello! What can you help me with?",    text = "Say hello")
    ),
    on_feedback = function(message_id, type) {
      message("[FEEDBACK] ", type, " on message=", message_id)
    }
  )
}

shinyApp(ui, server)
