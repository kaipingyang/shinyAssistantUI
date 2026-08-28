library(shiny)
library(shinyAssistantUI)

options(
  shinyAssistantUI.lazy_tool_result_threshold_bytes = 1024,
  shinyAssistantUI.lazy_tool_result_chunk_bytes = 64 * 1024,
  shinyAssistantUI.claude_tool_result_max_bytes = 1024 * 1024
)

make_large_result <- function(prefix, n = 30000L) {
  paste(sprintf("%s-LINE-%05d %s", prefix, seq_len(n), strrep("x", 24)), collapse = "\n")
}

live_result <- make_large_result("LAZY-LIVE")
history_result <- make_large_result("LAZY-HISTORY")
questions <- list(list(
  question = "Continue?",
  header = "Decision",
  multiSelect = FALSE,
  options = list(list(label = "Yes"), list(label = "No"))
))

ui <- fluidPage(
  tags$div(
    id = "fixture-metrics",
    tags$span(id = "installed-version", as.character(packageVersion("shinyAssistantUI"))),
    textOutput("lazy_request_count", inline = TRUE),
    textOutput("live_request_count", inline = TRUE),
    textOutput("history_request_count", inline = TRUE)
  ),
  assistantUIOutput("chat", height = "760px")
)

server <- function(input, output, session) {
  request_count <- reactiveVal(0L)
  live_request_count <- reactiveVal(0L)
  history_request_count <- reactiveVal(0L)
  output$lazy_request_count <- renderText(request_count())
  output$live_request_count <- renderText(live_request_count())
  output$history_request_count <- renderText(history_request_count())

  handler <- function(message, on_tool_call, on_tool_result, on_done, ...) {
    on_tool_call(
      "live-lazy-tool", "Bash",
      list(command = "synthetic live result"),
      annotations = list(defaultOpen = FALSE)
    )
    on_tool_result("live-lazy-tool", live_result)

    on_tool_call(
      "live-write-tool", "Write",
      list(file_path = "report.md", content = paste0("# Report\n\n", strrep("content\n", 30)))
    )
    on_tool_result("live-write-tool", "File written")

    on_tool_call(
      "live-ask-tool", "AskUserQuestion",
      list(questions = questions),
      annotations = list(requiresApproval = TRUE, defaultOpen = TRUE)
    )
  }

  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      send_thread(list(
        list(
          id = "history-user",
          role = "user",
          content = list(list(type = "text", text = "Historical lazy result"))
        ),
        list(
          id = "history-assistant",
          role = "assistant",
          status = list(type = "complete", reason = "stop"),
          content = list(list(
            type = "tool-call",
            toolCallId = "history-lazy-tool",
            toolName = "Bash",
            args = list(command = "synthetic history result"),
            argsText = "{\"command\":\"synthetic history result\"}",
            result = history_result,
            isError = FALSE,
            artifact = list(defaultOpen = FALSE)
          ))
        )
      ), has_more = FALSE)
    }
  )

  observeEvent(input$chat_input_tool_result_chunk, {
    request_count(request_count() + 1L)
    tool_id <- input$chat_input_tool_result_chunk$toolCallId
    if (identical(tool_id, "live-lazy-tool")) {
      live_request_count(live_request_count() + 1L)
    } else if (identical(tool_id, "history-lazy-tool")) {
      history_request_count(history_request_count() + 1L)
    }
  }, ignoreInit = TRUE)

  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(list(
      id = "lazy-history-session",
      title = "Lazy history",
      preview = "Historical lazy result",
      createdAt = as.numeric(Sys.time()) * 1000
    ))))
  }, once = TRUE)
}

app <- shinyApp(ui, server)
