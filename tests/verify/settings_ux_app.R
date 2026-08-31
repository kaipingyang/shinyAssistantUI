library(shiny)
library(shinyAssistantUI)

# Plan 45 批1 验证:Settings 重定位(默认模式 + 可见性)+ composer 内联按可见性过滤。
handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result,
                    on_usage = NULL, ...) {
  on_tool_call(
    "typography-write", "Write",
    args = list(
      file_path = "TYPOGRAPHY.md",
      content = "# TOOL HEADING\n\nTOOL MARKDOWN BODY\n\n```r\nx <- 1\n```"
    ),
    annotations = list(defaultOpen = TRUE, resultType = "markdown")
  )
  on_tool_result(
    "typography-write",
    "TOOL RESULT BODY with `inline code`.",
    is_error = FALSE
  )
  on_chunk("# HEADING\n\nASSISTANT BODY\n\n```r\n1 + 1\n```")
  if (!is.null(on_usage)) {
    on_usage(tokens = 1200L, context_tokens = 1200L, context_window = 200000L)
  }
  on_done()
}
attr(handler, "ui_capabilities") <- list(
  permission_mode = list(value = "default", options = list(
    list(value = "askAll", label = "Strict"),
    list(value = "default", label = "Manual"),
    list(value = "plan", label = "Plan"),
    list(value = "acceptEdits", label = "Auto-edit"),
    list(value = "bypassPermissions", label = "Bypass"),
    list(value = "yolo", label = "YOLO")
  )),
  thinking = list(value = "default", options = list(list(value = "default", label = "Default"))),
  model = list(value = "sonnet", options = list(
    list(value = "sonnet", label = "Sonnet"), list(value = "opus", label = "Opus")
  ))
)
# 需 action_handler attr 才会暴露 ui_capabilities(见 server.R .uses_handler_action)。
attr(handler, "action_handler") <- function(id, thread_id, send_action_result = function(...) {}) {
  send_action_result(paste("ok", id), "ok", value = sub("^[a-z]+:", "", id))
}

history_loader <- function(session_id, thread_id, send_thread, ...) {
  send_thread(list(list(
    id = paste0("history-", thread_id),
    role = "assistant",
    content = list(list(
      type = "text",
      text = "# HISTORY HEADING\n\nHISTORY BODY"
    ))
  )))
}

ui <- assistantUIPage(div(style = "width:680px;height:100vh", assistantUIOutput("chat", height = "92vh")))
server <- function(input, output, session) {
  edit_presentation <- new.env(parent = emptyenv())
  edit_presentation$enabled <- TRUE
  ctrl <- assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    persistence = "server", on_session_load = history_loader,
    show_usage = TRUE, context_window = 200000L, usage_style = "ring",
    default_permission_mode = "default",
    on_set_default_permission_mode = function(m) message("SET_DEFAULT_MODE=", m),
    mode_visibility = list(showBypass = TRUE, showYolo = FALSE),  # YOLO 初始隐藏
    on_set_mode_visibility = function(v) message("SET_VIS bypass=", isTRUE(v$showBypass), " yolo=", isTRUE(v$showYolo)),
    composer_density = getOption("AUI_TEST_DENSITY", Sys.getenv("AUI_TEST_DENSITY", "comfortable")),
    on_set_composer_density = function(d) message("SET_DENSITY=", d),
    assistant_text_size = "medium",
    on_set_assistant_text_size = function(value) message("SET_TEXT_SIZE=", value),
    run_r_enabled = TRUE,
    on_toggle_run_r = function(v) message("SET_RUNR=", isTRUE(v)),
    show_claude_edits_in_rstudio = TRUE,
    on_toggle_claude_edits_in_rstudio = function(v) {
      edit_presentation$enabled <- isTRUE(v)
      message("SET_CLAUDE_EDITS=", isTRUE(v))
    },
    on_edits = function(...) {
      if (isTRUE(edit_presentation$enabled)) message("PUBLISH_EDIT_MARKERS")
      invisible(isTRUE(edit_presentation$enabled))
    },
    on_open_file = function(path, ...) message("OPEN_EDIT=", path)
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(list(
      id = "settings-history",
      title = "Settings history",
      preview = "History size fixture",
      createdAt = "2026-08-18T00:00:00Z"
    ))))
  }, once = TRUE)
}
shinyApp(ui, server)
