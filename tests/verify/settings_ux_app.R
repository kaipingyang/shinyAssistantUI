library(shiny)
library(shinyAssistantUI)

# Plan 45 批1 验证:Settings 重定位(默认模式 + 可见性)+ composer 内联按可见性过滤。
handler <- function(message, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }
attr(handler, "ui_capabilities") <- list(
  permission_mode = list(value = "default", options = list(
    list(value = "askAll", label = "Strict"),
    list(value = "default", label = "Manual"),
    list(value = "plan", label = "Plan"),
    list(value = "acceptEdits", label = "Auto-edit"),
    list(value = "bypassPermissions", label = "Bypass"),
    list(value = "yolo", label = "YOLO")
  )),
  thinking = list(value = "default", options = list(list(value = "default", label = "Default")))
)
# 需 action_handler attr 才会暴露 ui_capabilities(见 server.R .uses_handler_action)。
attr(handler, "action_handler") <- function(id, thread_id, send_action_result = function(...) {}) {
  send_action_result(paste("ok", id), "ok", value = sub("^[a-z]+:", "", id))
}

ui <- assistantUIPage(div(style = "width:680px;height:100vh", assistantUIOutput("chat", height = "92vh")))
server <- function(input, output, session) {
  assistantUIServer(
    "chat", handler = handler, show_thread_list = TRUE,
    default_permission_mode = "default",
    on_set_default_permission_mode = function(m) message("SET_DEFAULT_MODE=", m),
    mode_visibility = list(showBypass = TRUE, showYolo = FALSE),  # YOLO 初始隐藏
    on_set_mode_visibility = function(v) message("SET_VIS bypass=", isTRUE(v$showBypass), " yolo=", isTRUE(v$showYolo))
  )
}
shinyApp(ui, server)
