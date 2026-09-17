suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

expected_package <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
stopifnot(identical(
  normalizePath(find.package("shinyAssistantUI"), winslash = "/", mustWork = TRUE),
  expected_package
))

history_messages <- unlist(lapply(seq_len(160L), function(index) {
  list(
    list(
      id = sprintf("bounded-user-%03d", index),
      role = "user",
      content = list(list(
        type = "text",
        text = sprintf("BOUNDED_USER_%03d", index)
      ))
    ),
    list(
      id = sprintf("bounded-assistant-%03d", index),
      role = "assistant",
      content = list(list(
        type = "text",
        text = sprintf("BOUNDED_ASSISTANT_%03d", index)
      ))
    )
  )
}), recursive = FALSE)

ui <- fluidPage(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  tags$div(
    id = "history-request-count",
    style = "position:fixed;left:-10000px;top:0;width:1px;height:1px;overflow:hidden",
    textOutput("requests")
  ),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  request_count <- reactiveVal(0L)
  output$requests <- renderText(request_count())
  outputOptions(output, "requests", suspendWhenHidden = FALSE)

  handler <- function(message, on_chunk, on_done, ...) {
    on_chunk(paste0("ECHO[", message, "]"))
    on_done()
  }

  controls <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "client",
    on_session_load = function(session_id, thread_id, send_thread,
                               cursor = NULL, limit = 50L, ...) {
      request_count(request_count() + 1L)
      upper <- if (is.null(cursor)) length(history_messages) else as.integer(cursor)
      lower <- max(1L, upper - as.integer(limit) + 1L)
      next_cursor <- lower - 1L
      send_thread(
        history_messages[seq.int(lower, upper)],
        cursor = if (next_cursor > 0L) next_cursor else NULL,
        has_more = next_cursor > 0L
      )
    }
  )

  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(list(
      id = "bounded-history-session",
      title = "Bounded History Fixture",
      preview = "320 paged messages",
      createdAt = "2026-09-11T00:00:00Z"
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
