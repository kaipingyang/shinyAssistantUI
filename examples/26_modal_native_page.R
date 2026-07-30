# 26_modal_native_page.R
# Floating modal (pop-up) chat built on shinyAssistantUI's OWN page —
# `assistantUIPage()` (suppress_bootstrap = TRUE) — instead of bslib's
# `page_fluid()`. This avoids the Bootstrap-vs-widget theme conflict: the host
# page uses plain, scoped HTML/CSS, and the chat floats bottom-right.
#
# Run: set OPENAI_BASE_URL / OPENAI_MODEL / OPENAI_API_KEY (readRenviron),
#      then shiny::runApp("examples/26_modal_native_page.R").
library(shiny)
library(ellmer)
library(shinyAssistantUI)

# ── tools ─────────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3)
    conditions <- c("Sunny", "Partly Cloudy", "Cloudy", "Light Rain", "Rain",
                    "Windy", "Thunderstorm", "Snow")
    temp <- sample(45:85, 1)
    list(city = city, temperature = temp, unit = "F",
         condition = sample(conditions, 1),
         high = temp + sample(4:10, 1), low = temp - sample(4:10, 1),
         humidity = sample(40:90, 1), wind = sample(5:35, 1))
  },
  name = "get_weather", description = "Get current weather information for a city",
  arguments = list(city = type_string("The name of the city")),
  annotations = tool_annotations(title = "Weather Lookup", icon = "cloud-sun")
)

calculate <- tool(
  function(expression) {
    tryCatch(as.character(eval(parse(text = expression))),
             error = function(e) stop(conditionMessage(e)))
  },
  name = "calculate", description = "Evaluate a mathematical expression (R syntax)",
  arguments = list(expression = type_string("A valid R expression, e.g. 'sqrt(144)'")),
  annotations = tool_annotations(title = "Calculator", icon = "calculator")
)

# ── handler (ellmer, OpenAI-compatible backend) ───────────────────────────────
handler <- make_ellmer_handler(
  chat = function() chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  ),
  tools = list(get_weather, calculate)
)

# ── UI: shinyAssistantUI native page (no bslib) ───────────────────────────────
ui <- assistantUIPage(
  title = "Modal Assistant — native page",
  tags$style(HTML("
    :root { --ink:#1f2328; --muted:#656d76; --line:#e2e5e9; --bg:#f6f8fa; }
    .aui-page { font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif;
                color: var(--ink); background: var(--bg); }
    /* assistantUIPage sets body overflow:hidden -> give host content its own scroller */
    .host-scroll { height: 100%; overflow-y: auto; box-sizing: border-box;
                   padding: 40px 24px 120px; }
    .host-inner { max-width: 760px; margin: 0 auto; }
    .host-inner h1 { font-size: 1.6rem; margin: 0 0 6px; }
    .host-inner .sub { color: var(--muted); margin: 0 0 28px; }
    .card { background:#fff; border:1px solid var(--line); border-radius:12px;
            padding:18px 20px; margin-bottom:16px; box-shadow:0 1px 2px rgba(0,0,0,.04); }
    .card h2 { font-size: 1rem; margin: 0 0 10px; }
    .card ul { margin: 0; padding-left: 18px; color: var(--muted); line-height: 1.8; }
    code { background:#eef1f4; padding:1px 6px; border-radius:6px; font-size:.85em; }
    /* floating chat, bottom-right */
    .modal-wrap { position: fixed; bottom: 24px; right: 24px; z-index: 9999; }
    /* composer input box: white instead of the default muted gray */
    .aui-composer-root { --composer-bg: #ffffff; }
  ")),
  div(class = "host-scroll",
    div(class = "host-inner",
      h1("Modal Assistant"),
      p(class = "sub",
        "Built on shinyAssistantUI's own page (no bslib). ",
        "Click the bot icon at the bottom-right to open the chat."),
      div(class = "card",
        h2("Try it"),
        tags$ul(
          tags$li("Click the bot icon → a floating panel opens"),
          tags$li("Ask: ", code("What's the weather in Tokyo?")),
          tags$li("Ask: ", code("Calculate sqrt(1764)")),
          tags$li("Click the icon again to close; scroll the page — it stays put")
        )
      ),
      div(class = "card",
        h2("Why the native page?"),
        tags$ul(
          tags$li("assistantUIPage() suppresses Bootstrap -> no theme clash with the widget"),
          tags$li("Host content here is plain scoped HTML/CSS, not bslib components")
        )
      ),
      # filler so the page scrolls (proves the modal stays fixed)
      lapply(1:6, function(i) div(class = "card",
        h2(paste("Section", i)),
        p(style = "color:var(--muted);margin:0;",
          "Scrollable host content — the chat bubble stays anchored bottom-right.")))
    )
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
    )
  )
}

shinyApp(ui, server)
