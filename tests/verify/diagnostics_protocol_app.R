suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

mode <- Sys.getenv("SAU_DIAGNOSTICS_MODE", "disabled")
root <- Sys.getenv("SAU_DIAGNOSTICS_ROOT", "")
stopifnot(mode %in% c("disabled", "enabled"), nzchar(root))
expected_root <- file.path(path.expand("~"), ".claude_addin", "diagnostics")
stopifnot(identical(normalizePath(expected_root, winslash = "/", mustWork = FALSE),
                    normalizePath(root, winslash = "/", mustWork = FALSE)))
cat("installed=", normalizePath(find.package("shinyAssistantUI"), winslash = "/"), "\n", sep = "")
cat("mode=", mode, "\n", sep = "")

history_messages <- list(
  list(
    id = "history-user-id-sentinel",
    role = "user",
    content = list(list(type = "text", text = "HISTORY_PROMPT_PRIVACY_SENTINEL"))
  ),
  list(
    id = "history-assistant-id-sentinel",
    role = "assistant",
    content = list(list(type = "text", text = "HISTORY_RESPONSE_PRIVACY_SENTINEL"))
  ),
  list(
    id = "history-tool-message-id-sentinel",
    role = "assistant",
    content = list(list(
      type = "tool-call",
      toolCallId = "RAW_TOOL_ID_PRIVACY_SENTINEL",
      toolName = "Read",
      args = list(file_path = "/private/HISTORY_PATH_PRIVACY_SENTINEL.txt"),
      argsText = '{"file_path":"/private/HISTORY_PATH_PRIVACY_SENTINEL.txt","token":"HISTORY_TOOL_ARGS_PRIVACY_SENTINEL"}',
      result = "HISTORY_TOOL_RESULT_PRIVACY_SENTINEL",
      isError = FALSE
    ))
  )
)

handler <- function(message, on_chunk, on_done, on_error, ...) {
  cat("RAW_STDERR_PRIVACY_SENTINEL\n", file = stderr())
  on_chunk("LIVE_RESPONSE_PRIVACY_SENTINEL")
  on_done()
}

memory_mib <- 1024^2
memory_config <- shinyAssistantUI:::.memory_guard_default_config()
memory_config$soft_pss_bytes <- 10 * memory_mib
memory_config$hard_pss_bytes <- 20 * memory_mib
memory_config$soft_rss_bytes <- 110 * memory_mib
memory_config$hard_rss_bytes <- 120 * memory_mib
memory_plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_config)
settings_plugin <- shinyAssistantUI:::.new_diagnostics_settings_addin_plugin(
  desired = identical(mode, "enabled"),
  show_performance_orb = TRUE,
  launch_enabled = identical(mode, "enabled"),
  environment_override = "none",
  launch_kind = "foreground"
)

memory_sample <- function(index) {
  state <- if (index >= 20L) "hard" else if (index >= 10L) "soft" else "normal"
  memory_plugin$observe(
    list(
      pss_bytes = index * memory_mib,
      rss_bytes = (index + 100L) * memory_mib,
      pid = "MEMORY_PID_PRIVACY_SENTINEL",
      path = "/private/MEMORY_PATH_PRIVACY_SENTINEL",
      prompt = "MEMORY_CONTENT_PRIVACY_SENTINEL",
      timestamp = "MEMORY_TIMESTAMP_PRIVACY_SENTINEL"
    ),
    previous_state = state,
    next_state = state
  )
}

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  actionButton(
    "remount_chat", "Remount chat",
    style = "position:fixed;left:50%;top:4px;z-index:10000"
  ),
  uiOutput("chat_host"),
  title = "Diagnostics verification"
)
server <- function(input, output, session) {
  chat_mounted <- reactiveVal(TRUE)
  output$chat_host <- renderUI({
    if (!isTRUE(chat_mounted())) return(NULL)
    assistantUIOutput("chat", height = "100vh")
  })
  observeEvent(input$remount_chat, {
    chat_mounted(FALSE)
    later::later(function() chat_mounted(TRUE), delay = 0.3)
  }, ignoreInit = TRUE)
  diagnostics <- if (identical(mode, "enabled")) {
    list(
      enabled = TRUE,
      frontend_batch_ms = 250L,
      frontend_batch_max = 20L,
      frontend_queue_max = 40L,
      frontend_batch_max_bytes = 16384L,
      event_max_bytes = 4096L,
      buffer_max_events = 10L,
      flush_interval_ms = 250L,
      max_file_bytes = 65536L,
      max_files = 2L
    )
  } else {
    NULL
  }
  settings_binding <- settings_plugin$bind(session, "chat_input")
  memory_binding <- memory_plugin$bind(session, "chat_input")
  attr(handler, "ui_addons") <- list(
    diagnosticsSettings = settings_binding$config,
    diagnosticsLaunch = list(
      version = 2L,
      launchEnabled = identical(mode, "enabled"),
      environmentOverride = "none",
      launchKind = "foreground",
      writerStartup = if (identical(mode, "enabled")) "started" else "off"
    ),
    memoryMonitor = memory_binding$config
  )
  api <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    diagnostics = diagnostics,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      stopifnot(identical(session_id, "RAW_SESSION_ID_PRIVACY_SENTINEL"))
      send_thread(history_messages)
    }
  )
  for (index in seq_len(25L)) memory_sample(index)
  injected_hidden_sample <- FALSE
  observeEvent(
    input$chat_input_memory_monitor_visible,
    {
      message <- input$chat_input_memory_monitor_visible
      if (identical(message$visible, FALSE) && !injected_hidden_sample) {
        injected_hidden_sample <<- TRUE
        memory_sample(26L)
      }
    },
    ignoreNULL = TRUE,
    ignoreInit = TRUE,
    priority = -10
  )
  session$onFlushed(function() {
    api$send_sessions(list(sessions = list(list(
      id = "RAW_SESSION_ID_PRIVACY_SENTINEL",
      title = "Diagnostics history",
      preview = "History fixture",
      createdAt = "2026-09-14T00:00:00Z"
    ))))
  }, once = TRUE)
}
onStop(function() {
  settings_plugin$dispose()
  memory_plugin$dispose()
})

shinyApp(ui, server)
