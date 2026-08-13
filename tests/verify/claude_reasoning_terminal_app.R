library(shiny)
library(shinyAssistantUI)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "Claude reasoning terminal verification"
)

server <- function(input, output, session) {
  queue <- list()
  send_count <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$get_server_info <- function() list(commands = list(), output_styles = list())
  client$deny_tool <- function(...) invisible(NULL)
  client$approve_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$send <- function(content) {
    send_count <<- send_count + 1L
    if (send_count == 1L) {
      queue <<- list(
        ClaudeAgentSDK::StreamEvent(
          uuid = "browser-thinking",
          session_id = "browser-terminal-session",
          event = list(
            type = "content_block_delta", index = 0,
            delta = list(
              type = "thinking_delta",
              thinking = "Reasoning without a final answer."
            )
          )
        ),
        ClaudeAgentSDK::ResultMessage(
          subtype = "success", duration_ms = 1, duration_api_ms = 1,
          is_error = FALSE, num_turns = 1,
          session_id = "browser-terminal-session",
          result = NULL, stop_reason = "end_turn"
        )
      )
    } else {
      queue <<- list(
        ClaudeAgentSDK::AssistantMessage(
          content = list(ClaudeAgentSDK::TextBlock("Recovered final answer.")),
          model = "mock-model", stop_reason = "end_turn",
          session_id = "browser-terminal-session"
        ),
        ClaudeAgentSDK::ResultMessage(
          subtype = "success", duration_ms = 1, duration_api_ms = 1,
          is_error = FALSE, num_turns = 1,
          session_id = "browser-terminal-session",
          result = "Recovered final answer.", stop_reason = "end_turn"
        )
      )
    }
    invisible(NULL)
  }
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }

  mock_scope <- new.env(parent = environment())
  testthat::local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client,
    .package = "shinyAssistantUI",
    .env = mock_scope
  )

  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )

  assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = FALSE
  )
}

shinyApp(ui, server)
