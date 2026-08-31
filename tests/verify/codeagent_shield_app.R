# Deterministic installed-package fixture for Plan 65. No network/LLM required.
library(shiny)
library(shinyAssistantUI)

SECRET <- "PLAN65_BROWSER_PRIVATE_4Q"

new_fake_shield <- function() {
  structure(
    list(
      scan_prompt = function(text, ...) {
        list(action = "pass", text = text)
      },
      scan_response = function(text, ...) {
        if (grepl(SECRET, text, fixed = TRUE)) {
          return(list(action = "redact", text = "Shielded answer: [PROTECTED]"))
        }
        list(action = "pass", text = text)
      },
      close = function() invisible(NULL)
    ),
    class = "DataShield"
  )
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "codeagent Data Shield deterministic fixture"
)

server <- function(input, output, session) {
  client <- structure(
    list(
      chat = list(),
      settings = list(model = "fixture-model", model_limit = 1000L),
      data_shield = new_fake_shield()
    ),
    class = "CodeagentClient"
  )

  fake_stream <- function(client, input, on_delta = NULL, on_thinking = NULL,
                          on_tool_request = NULL, on_tool_result = NULL,
                          on_error = NULL, on_usage = NULL, ...) {
    on_delta("Raw PLAN65_BROWSER_")
    on_delta("PRIVATE_4Q")
    on_thinking(paste("hidden reasoning", SECRET))
    on_tool_request(list(
      id = "shield-tool", name = "RunR",
      arguments = list(code = paste("print", SECRET)),
      intent = paste("inspect", SECRET)
    ))
    on_tool_result(list(
      id = "shield-tool", name = "RunR", value = "SAFE_TOOL_RESULT_65", is_error = FALSE,
      display = list(
        markdown = paste("unsafe table", SECRET),
        toolcard = list(
          kind = "image",
          payload = list(images = list(list(
            mime = "image/png", b64 = paste0("UNSAFE_", SECRET)
          )))
        )
      )
    ))
    on_usage(list(
      n_tokens = 123L,
      model_limit = 1000L,
      cost_last = 0.02
    ))
    promises::promise(function(resolve, reject) {
      later::later(function() {
        resolve(list(
          text = paste("Raw", SECRET),
          usage = NULL,
          stop_reason = "completed"
        ))
      }, delay = 0.6)
    })
  }

  handler <- make_codeagent_handler(
    client_factory = function() client,
    stream_fn = fake_stream,
    gate_fn = function(...) NULL
  )

  assistantUIServer(
    "chat",
    handler = handler,
    show_usage = TRUE,
    context_window = 1000L,
    usage_style = "ring",
    welcome_message = "Deterministic Data Shield fixture ready."
  )
}

shinyApp(ui, server)
