suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

expected_package <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
stopifnot(identical(
  normalizePath(find.package("shinyAssistantUI"), winslash = "/", mustWork = TRUE),
  expected_package
))

thread_ids <- sprintf("memory-thread-%02d", seq_len(20L))
histories <- setNames(lapply(seq_along(thread_ids), function(thread_index) {
  unlist(lapply(seq_len(250L), function(turn) {
    list(
      list(
        id = sprintf("memory-%02d-user-%03d", thread_index, turn),
        role = "user",
        content = list(list(
          type = "text",
          text = sprintf("MEMORY_%02d_USER_%03d_%s", thread_index, turn,
                         paste(rep("payload", 8L), collapse = "_"))
        ))
      ),
      list(
        id = sprintf("memory-%02d-assistant-%03d", thread_index, turn),
        role = "assistant",
        content = list(list(
          type = "text",
          text = sprintf("MEMORY_%02d_ASSISTANT_%03d_%s", thread_index, turn,
                         paste(rep("response", 8L), collapse = "_"))
        ))
      )
    )
  }), recursive = FALSE)
}), thread_ids)
stopifnot(sum(lengths(histories)) == 10000L)

ui <- fluidPage(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  tags$div(
    id = "memory-probe",
    style = "position:fixed;left:-10000px;top:0;width:1px;height:1px;overflow:hidden",
    textOutput("probe")
  ),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  page_reads <- reactiveVal(0L)
  output$probe <- renderText(sprintf("reads=%d threads=20 total=10000", page_reads()))
  outputOptions(output, "probe", suspendWhenHidden = FALSE)
  observeEvent(input$force_gc, {
    invisible(gc(full = TRUE))
  }, ignoreInit = TRUE)

  controls <- assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, ...) {
      on_chunk(paste0("ECHO[", message, "]"))
      on_done()
    },
    show_thread_list = TRUE,
    persistence = "client",
    on_session_load = function(session_id, thread_id, send_thread,
                               cursor = NULL, limit = 50L, ...) {
      page_reads(page_reads() + 1L)
      messages <- histories[[session_id]]
      # Thread 1 is the canonical tail window; thread 2 is the canonical old
      # page. Repeated A/B selection exercises authoritative replacement and
      # eviction without allowing UI button re-entry to overlap requests.
      window <- if (identical(session_id, thread_ids[[2L]])) {
        messages[seq_len(240L)]
      } else if (identical(session_id, thread_ids[[1L]])) {
        tail(messages, 240L)
      } else {
        tail(messages, 2L)
      }
      send_thread(window, cursor = NULL, has_more = FALSE)
    }
  )

  session$onFlushed(function() {
    controls$send_sessions(list(sessions = lapply(seq_along(thread_ids), function(index) {
      list(
        id = thread_ids[[index]],
        title = sprintf("Memory Thread %02d", index),
        preview = "500 synthetic messages",
        createdAt = sprintf("2026-09-11T00:%02d:00Z", index - 1L)
      )
    })))
  }, once = TRUE)
}

shinyApp(ui, server)
