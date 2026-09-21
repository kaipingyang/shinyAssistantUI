suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

make_history <- function(prefix, n) {
  lapply(seq_len(n), function(i) {
    id <- sprintf("%s-%03d", prefix, i)
    role <- "assistant"
    if (i %% 3L == 1L) role <- "user"
    content <- list(list(
      type = "text",
      text = sprintf("QUESTION_%03d: History anchor and editor fixture", i)
    ))
    if (i %% 3L == 2L) {
      args <- list(file_path = sprintf("/tmp/fixture-%03d.R", i))
      content <- list(list(
        type = "tool-call", toolCallId = paste0("call-", id),
        toolName = "Read", args = args,
        argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
        result = paste(rep(sprintf("TOOL_%03d result line", i), 12L + i %% 20L), collapse = "\n"),
        isError = FALSE
      ))
    } else if (identical(role, "assistant")) {
      content <- list(list(
        type = "text",
        text = paste0(
          sprintf("ANSWER_%03d\n\n", i),
          paste(rep("Variable height paragraph with **formatted** content.", 1L + i %% 7L),
                collapse = "\n\n")
        )
      ))
    }
    list(id = id, role = role, content = content)
  })
}
history <- make_history("history", 360L)
other_history <- make_history("other", 12L)

ui <- bslib::page_fluid(
  tags$style("html,body,.container-fluid{margin:0;padding:0}"),
  assistantUIOutput("chat", height = "100vh"),
  tags$div(
    style = "position:fixed;left:-10000px;top:0",
    textOutput("history_requests"),
    textOutput("stream_finished")
  )
)

server <- function(input, output, session) {
  requests <- reactiveVal(0L)
  finished <- reactiveVal(FALSE)
  output$history_requests <- renderText(requests())
  output$stream_finished <- renderText(as.character(finished()))
  outputOptions(output, "history_requests", suspendWhenHidden = FALSE)
  outputOptions(output, "stream_finished", suspendWhenHidden = FALSE)

  handler <- function(message, on_chunk, on_done, register_cancel, ...) {
    cancelled <- FALSE
    finished(FALSE)
    register_cancel(function() cancelled <<- TRUE)
    coro::async(function() {
      for (i in seq_len(80L)) {
        if (cancelled) break
        on_chunk(sprintf("STREAM_%03d: visible streaming paragraph.\n\n", i))
        coro::await(promises::promise(function(resolve, reject) {
          later::later(function() resolve(NULL), 0.07)
        }))
      }
      finished(TRUE)
      on_done()
    })()
  }

  controls <- assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE, persistence = "client",
    on_session_load = function(session_id, thread_id, send_thread,
                               cursor = NULL, limit = 50L, ...) {
      requests(requests() + 1L)
      if (identical(session_id, "other-history")) {
        send_thread(other_history, cursor = NULL, has_more = FALSE)
        return(invisible(NULL))
      }
      upper <- length(history)
      count <- 90L
      if (!is.null(cursor)) {
        upper <- as.integer(cursor)
        count <- 60L
      }
      lower <- max(1L, upper - count + 1L)
      next_cursor <- lower - 1L
      send_thread(history[seq.int(lower, upper)],
                  cursor = if (next_cursor > 0L) next_cursor else NULL,
                  has_more = next_cursor > 0L)
    }
  )
  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(
      list(id = "virtual-history", title = "Virtual History",
           createdAt = "2026-09-18T00:00:00Z"),
      list(id = "other-history", title = "Other History",
           createdAt = "2026-09-17T00:00:00Z")
    )))
  }, once = TRUE)
}
shinyApp(ui, server)
