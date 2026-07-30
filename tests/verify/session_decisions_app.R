library(shiny)
library(shinyAssistantUI)

# 验证 Bug a/c:打开历史 session 时,工具卡回填当时的允许/拒绝状态
# (artifact.approvalResult → "✓ Approved" / "✕ Denied")。用 canned on_session_load
# 直接下发含 approvalResult 注解的历史线程,不需要真实后端,专测前端渲染 + 无崩溃。
handler <- function(message, on_chunk, on_done, ...) { on_chunk("ok"); on_done() }

ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))

server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_session_load = function(session_id, thread_id, send_thread, cursor = NULL, limit = 50L) {
      send_thread(messages = list(
        list(id = "hist-u", role = "user",
             content = list(list(type = "text", text = "please run some tools"))),
        list(id = "hist-a", role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(
               list(type = "tool-call", toolCallId = "tu_deny", toolName = "Bash",
                    args = list(command = "rm -rf /important"),
                    argsText = "{\"command\":\"rm -rf /important\"}",
                    result = "Denied by user", isError = TRUE,
                    artifact = list(isError = TRUE, approvalResult = "denied")),
               list(type = "tool-call", toolCallId = "tu_ok", toolName = "Read",
                    args = list(file_path = "/tmp/notes.txt"),
                    argsText = "{\"file_path\":\"/tmp/notes.txt\"}",
                    result = "line1\nline2", isError = FALSE,
                    artifact = list(isError = FALSE, approvalResult = "approved"))
             ))
      ), has_more = FALSE)
    }
  )
  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(id = "sess-hist", title = "History with approvals",
           preview = "please run some tools", createdAt = as.numeric(Sys.time()) * 1000)
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
