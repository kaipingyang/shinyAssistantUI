suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})


`%||%` <- function(x, y) if (is.null(x) || !length(x)) y else x
set.seed(1231501L)
fixture_markdown <- "Fixture result 42."
fixture_expected_text <- "Fixture result 42."
fixture_expected_semantic <- "<p>Fixture result 42.</p>"
fixture_expected_sha <- Sys.getenv("SAU_PLAN123_EXPECTED_SHA", "")
stopifnot(grepl("^[0-9a-f]{64}$", fixture_expected_sha))

history_messages <- list(
  list(id = "fixture-history-user", role = "user",
       content = list(list(type = "text", text = "Fixture history request"))),
  list(id = "fixture-history-assistant", role = "assistant",
       content = list(list(type = "text", text = "Fixture history response"))),
  list(id = "fixture-history-tool", role = "assistant", content = list(list(
    type = "tool-call", toolCallId = "fixture-history-tool-id", toolName = "Read",
    args = list(file_path = "fixture/history.md"),
    argsText = '{"file_path":"fixture/history.md"}', result = "fixture history result",
    isError = FALSE
  )))
)

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  actionButton("fixture_clear", "Clear fixture", style = "position:fixed;left:-10000px"),
  uiOutput("chat_host"),
  title = "Plan 123 deterministic performance fixture"
)

server <- function(input, output, session) {
  query <- shiny::parseQueryString(isolate(session$clientData$url_search) %||% "")
  experiment <- query$experiment %||% "D"
  condition <- query$condition %||% "control"
  stopifnot(experiment %in% c("D", "O"), condition %in% c("control", "candidate"))
  diagnostics_enabled <- if (identical(experiment, "D")) identical(condition, "candidate") else TRUE
  show_orb <- if (identical(experiment, "O")) identical(condition, "candidate") else TRUE

  mounted <- reactiveVal(TRUE)
  output$chat_host <- renderUI({
    if (!isTRUE(mounted())) return(NULL)
    assistantUIOutput("chat", height = "100vh")
  })

  settings_plugin <- shinyAssistantUI:::.new_diagnostics_settings_addin_plugin(
    desired = diagnostics_enabled,
    show_performance_orb = show_orb,
    launch_enabled = diagnostics_enabled,
    environment_override = "none",
    launch_kind = "foreground"
  )
  settings_binding <- settings_plugin$bind(session, "chat_input")

  handler <- function(message, on_chunk, on_done, on_error, on_tool_call,
                      on_tool_result, ...) {
    pieces <- strsplit(message, "::", fixed = TRUE)[[1L]]
    if (length(pieces) != 3L || !grepl("^[0-9]+$", pieces[[2L]]) ||
        !grepl("^[0-9a-f]{32}$", pieces[[3L]])) {
      on_error("invalid fixture request")
      return(invisible(NULL))
    }
    ordinal <- as.integer(pieces[[2L]])
    instance <- pieces[[3L]]
    callback_epoch_ms <- as.numeric(Sys.time()) * 1000
    session$sendCustomMessage("plan123-fixture-receive", list(
      fixtureOrdinal = ordinal,
      fixtureInstance = instance,
      expectedText = fixture_expected_text,
      expectedSha256 = fixture_expected_sha,
      markdown = fixture_markdown,
      callbackEpochMs = callback_epoch_ms
    ))
    cat("PLAN123_FIXTURE_STAGE chunk1\n", file = stderr())
    on_chunk("Fixture ")
    cat("PLAN123_FIXTURE_STAGE chunk2\n", file = stderr())
    on_chunk("result ")
    on_chunk("42.")
    cat("PLAN123_FIXTURE_STAGE tool_call\n", file = stderr())
    on_tool_call(
      paste0("fixture-tool-", ordinal), "Read",
      list(file_path = "fixture/input.md", ordinal = ordinal),
      annotations = list(defaultOpen = FALSE)
    )
    cat("PLAN123_FIXTURE_STAGE tool_result\n", file = stderr())
    on_tool_result(paste0("fixture-tool-", ordinal), "fixture tool result", is_error = FALSE)
    cat("PLAN123_FIXTURE_STAGE done\n", file = stderr())
    on_done()
  }

  attr(handler, "ui_addons") <- list(
    diagnosticsSettings = settings_binding$config,
    diagnosticsLaunch = list(
      version = 2L,
      launchEnabled = diagnostics_enabled,
      environmentOverride = "none",
      launchKind = "foreground",
      writerStartup = if (diagnostics_enabled) "started" else "off"
    )
  )
  diagnostics <- if (diagnostics_enabled) list(
    enabled = TRUE,
    frontend_batch_ms = 50L,
    frontend_batch_max = 20L,
    frontend_queue_max = 80L,
    frontend_batch_max_bytes = 16384L,
    event_max_bytes = 4096L,
    buffer_max_events = 20L,
    flush_interval_ms = 50L,
    max_file_bytes = 1048576L,
    max_files = 2L
  ) else NULL

  api <- assistantUIServer(
    "chat", handler = handler, diagnostics = diagnostics, latex = TRUE,
    show_thread_list = TRUE, persistence = "none",
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      if (identical(session_id, "fixture-history")) send_thread(history_messages)
    }
  )
  publish_history <- function() api$send_sessions(list(sessions = list(list(
    id = "fixture-history", title = "Fixture history", preview = "Deterministic history",
    createdAt = "2026-09-15T00:00:00Z"
  ))))
  session$onFlushed(publish_history, once = TRUE)

  observeEvent(input$fixture_clear, {
    mounted(FALSE)
    later::later(function() {
      mounted(TRUE)
      later::later(publish_history, delay = 0.05)
    }, delay = 0.15)
  }, ignoreInit = TRUE)
  session$onSessionEnded(function() settings_plugin$dispose())
}

shinyApp(ui, server)
