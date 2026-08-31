home_library <- Sys.getenv(
  "PLAN91_HOME_LIBRARY",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
.libPaths(c(home_library, .libPaths()))

suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

fixture_state <- new.env(parent = emptyenv())
fixture_state$target_push <- NULL
fixture_state$target_run_id <- NULL

fixture_snapshot <- function(result, include_report = FALSE) {
  assistant_content <- list(list(
    type = "tool-call",
    toolCallId = "fixture-tool",
    toolName = "Read",
    args = list(file_path = "fixture.txt"),
    argsText = '{"file_path":"fixture.txt"}',
    result = result,
    isError = FALSE
  ))
  if (isTRUE(include_report)) {
    assistant_content[[length(assistant_content) + 1L]] <- list(
      type = "text",
      text = "UNSOLICITED_CRON_REPORT"
    )
  }
  list(
    list(
      id = "h-user",
      role = "user",
      content = list(list(type = "text", text = "PLAN91_TARGET_SETUP"))
    ),
    list(
      id = "h-tool",
      role = "assistant",
      status = list(type = "complete", reason = "stop"),
      content = assistant_content
    )
  )
}

handler <- function(message, thread_id, run_id, on_chunk, on_done,
                    on_proactive_messages, ...) {
  if (identical(message, "PLAN91_TARGET_SETUP")) {
    fixture_state$target_push <- on_proactive_messages
    fixture_state$target_run_id <- run_id
    on_chunk("TARGET_INITIAL_LIVE")
    on_done()
    later::later(function() {
      fixture_state$target_push(
        messages = fixture_snapshot("PENDING_TOOL_RESULT"),
        revision = 1L,
        after_run_id = fixture_state$target_run_id
      )
    }, delay = 0.25)
    return(invisible(NULL))
  }

  if (identical(message, "PLAN91_CONTROL_SETUP")) {
    on_chunk("CONTROL_SELECTED")
    on_done()
    later::later(function() {
      if (!is.function(fixture_state$target_push)) return(invisible(NULL))
      fixture_state$target_push(
        messages = fixture_snapshot(
          "COMPLETED_TOOL_RESULT",
          include_report = TRUE
        ),
        revision = 2L,
        after_run_id = fixture_state$target_run_id
      )
    }, delay = 1.25)
    return(invisible(NULL))
  }

  on_chunk("UNEXPECTED_FIXTURE_MESSAGE")
  on_done()
}

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "Plan 91 proactive fixture"
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "client"
  )
}

shinyApp(ui, server)
