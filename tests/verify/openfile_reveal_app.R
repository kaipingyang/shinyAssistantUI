suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

# 记录 on_open_file 被调用的路径（stub 代替 rstudioapi::navigateToFile），
# 通过隐藏 DOM 元素回传给 Chromium 断言。
opened <- reactiveVal("")

# 处理器：普通消息回声；消息含 "do-edit" 时先发一个 Edit 工具调用+成功结果，
# 再 on_done —— 用于验证"编辑后揭示最近一次成功编辑"。
handler <- function(message, thread_id, on_chunk, on_done,
                    on_tool_call = NULL, on_tool_result = NULL, ...) {
  if (grepl("do-edit", message, fixed = TRUE)) {
    if (!is.null(on_tool_call)) {
      on_tool_call("tc-read", "Read", list(file_path = "R/server.R"))
      on_tool_result("tc-read", "read ok", is_error = FALSE)
      on_tool_call("tc-edit-1", "Edit", list(file_path = "R/handlers.R"))
      on_tool_result("tc-edit-1", "edit ok", is_error = FALSE)
      on_tool_call("tc-edit-2", "Write", list(file_path = "R/addin.R"))
      on_tool_result("tc-edit-2", "write ok", is_error = FALSE)
    }
    on_chunk("edited files: `addin.R`")
    on_done()
    return(invisible(NULL))
  }
  on_chunk(sprintf("ECHO[%s]", message))
  on_done()
}

ui <- fluidPage(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  # 隐藏元素回传 on_open_file 记录的路径
  tags$script(HTML(
    "Shiny.addCustomMessageHandler('opened_file', function(p){",
    "  var el=document.getElementById('opened-file-probe');",
    "  if(el){el.textContent=p||'';}",
    "});"
  )),
  tags$div(id = "opened-file-probe", style = "position:fixed;bottom:0;left:0;opacity:0;", ""),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  controls <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    persistence = "server",
    # 两个历史 thread 故意都写 `dm.R`，但 tool-call 完整路径不同：验证 session-load
    # 恢复后只读取当前 thread 的 messages，不会串到另一个 thread。
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      is_a <- identical(session_id, "open-hist-a")
      full_path <- if (is_a) "/project/history-a/dm.R" else "/project/history-b/dm.R"
      args <- if (is_a) list(file_path = full_path) else list(path = full_path)
      label <- if (is_a) "Historical A" else "Historical B"
      send_thread(messages = list(
        list(id = paste0("hist-u-", if (is_a) "a" else "b"), role = "user",
             content = list(list(type = "text", text = paste("open", label)))),
        list(id = paste0("hist-a-", if (is_a) "a" else "b"), role = "assistant",
             status = list(type = "complete", reason = "stop"),
             content = list(
               list(type = "tool-call", toolCallId = paste0("hist-tool-", if (is_a) "a" else "b"),
                    toolName = "Read", args = args,
                    argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
                    result = "read ok", isError = FALSE, artifact = list()),
               list(type = "text", text = paste0(label, ": `dm.R`"))
             ))
      ), has_more = FALSE)
    },
    # 仅有活动文件、无选区（复现“文件 chip 显示但没有选中文本”的场景）
    ide_context_provider = function() list(path = "/tmp/demo.R", rel = "R/demo.R"),
    on_open_file = function(path, line = NULL) {
      opened(path)
      session$sendCustomMessage("opened_file", path)
    }
  )

  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(
      list(id = "open-hist-a", title = "Open history A", preview = "Historical A",
           createdAt = as.numeric(Sys.time()) * 1000),
      list(id = "open-hist-b", title = "Open history B", preview = "Historical B",
           createdAt = as.numeric(Sys.time()) * 1000 - 1)
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
