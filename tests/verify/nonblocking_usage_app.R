suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
  library(ClaudeAgentSDK)
  library(promises)
})

queue <- list()
turn <- 0L
probe_calls <- 0L
pending_probe <- NULL
probe_ready_at <- NULL
fixture_started_at <- Sys.time()
fixture_log <- function(event) {
  message(sprintf("[fixture %.3fs] %s", as.numeric(Sys.time() - fixture_started_at), event))
}
client <- new.env(parent = emptyenv())
client$connect <- function() invisible(NULL)
client$disconnect <- function() invisible(NULL)
client$deny_tool <- function(...) invisible(NULL)
client$approve_tool <- function(...) invisible(NULL)
client$interrupt <- function(...) invisible(NULL)
client$get_server_info <- function() list(commands = list(), output_styles = list())
client$send <- function(content) {
  turn <<- turn + 1L
  fixture_log(paste0("send turn=", turn))
  label <- paste0("reply-", turn)
  queue <<- c(queue, list(
    ClaudeAgentSDK::AssistantMessage(
      content = list(ClaudeAgentSDK::TextBlock(label)),
      model = "browser-fixture",
      session_id = "browser-fixture-session"
    ),
    ClaudeAgentSDK::ResultMessage(
      subtype = "success",
      duration_ms = 10,
      duration_api_ms = 8,
      is_error = FALSE,
      num_turns = turn,
      session_id = "browser-fixture-session",
      stop_reason = "end_turn",
      total_cost_usd = 0.001,
      usage = list(input_tokens = 10L * turn)
    )
  ))
  invisible(NULL)
}
client$poll_messages <- function() {
  if (!is.null(pending_probe) && Sys.time() >= probe_ready_at) {
    callback <- pending_probe
    pending_probe <<- NULL
    probe_ready_at <<- NULL
    fixture_log("dispatch delayed probe=1")
    callback(list(totalTokens = 111111L, rawMaxTokens = 1000000L))
  }
  current <- queue
  queue <<- list()
  current
}
client$get_context_usage_async <- function(timeout_ms = Inf,
                                           on_fulfilled = NULL,
                                           on_rejected = NULL) {
  probe_calls <<- probe_calls + 1L
  call_number <- probe_calls
  fixture_log(paste0("async callback probe=", call_number))
  if (identical(call_number, 1L)) {
    pending_probe <<- on_fulfilled
    probe_ready_at <<- Sys.time() + 8
  } else {
    on_fulfilled(list(totalTokens = 250000L, rawMaxTokens = 1000000L))
  }
  invisible(paste0("fixture-probe-", call_number))
}

testthat::local_mocked_bindings(
  .new_claude_client = function(options) client,
  .package = "shinyAssistantUI",
  .env = globalenv()
)

handler <- make_claude_handler(
  options = list(
    permission_mode = "default",
    permission_prompt_tool_name = "stdio",
    include_partial_messages = TRUE
  ),
  session_map_path = tempfile(fileext = ".rds")
)


ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  div(style = "height:100vh", assistantUIOutput("chat", height = "90vh"))
)
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = handler,
    show_usage = TRUE,
    context_window = 1000000L,
    usage_style = "ring"
  )
}
shinyApp(ui, server)
