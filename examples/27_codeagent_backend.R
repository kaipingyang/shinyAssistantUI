# examples/27_codeagent_backend.R
# ─────────────────────────────────────────────────────────────────────────────
# codeagent as the backend engine (Plan 51, Phase A).
#
# Uses make_codeagent_handler() so the chat is driven by a full `codeagent`
# agent (harness: multi-turn self-heal, compaction, skills/hooks, lossless
# session) instead of a bare ellmer Chat. Phase A = streaming + tool display
# forwarding; no permission gating / no concurrent sub-agents yet.
#
# PREREQUISITES
#   1. install.packages-equivalent: the `codeagent` package must be installed.
#   2. A `.Renviron` at the repo root with an OpenAI-compatible endpoint:
#        OPENAI_BASE_URL=...      OPENAI_MODEL=...      OPENAI_API_KEY=...
#      (same convention as examples/09 and 10).
#
# RUN
#   shiny::runApp("examples/27_codeagent_backend.R")
#   then ask e.g.  "What is 12 * 13?"  (the model calls the calculate tool)
# ─────────────────────────────────────────────────────────────────────────────
library(shiny)
library(ellmer)
library(codeagent)
devtools::load_all(here::here())

readRenviron(here::here(".Renviron"))

# A toy domain tool the host registers on its own chat. codeagent's harness runs
# it (register_tools = FALSE means codeagent adds NO coding tools of its own).
calculate <- tool(
  function(expression) {
    tryCatch(as.character(eval(parse(text = expression))),
             error = function(e) stop(conditionMessage(e)))
  },
  name        = "calculate",
  description = "Evaluate a mathematical expression (R syntax)",
  arguments   = list(expression = type_string("A valid R expression, e.g. 'sqrt(144)'")),
  annotations = tool_annotations(title = "Calculator", icon = "calculator")
)

client_factory <- function() {
  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  chat$register_tools(list(calculate))
  # harness-only client: codeagent registers none of its own coding tools.
  codeagent::codeagent_client(chat = chat, register_tools = FALSE,
                              permission_mode = "default")
}

handler <- make_codeagent_handler(client_factory)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "codeagent backend"
)
server <- function(input, output, session) {
  assistantUIServer("chat", handler = handler)
}
shinyApp(ui, server)
