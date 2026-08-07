# Fixture: Write工具的Markdown源码表格必须保持逐行文本布局，live/history一致。
library(shiny)
library(shinyAssistantUI)

md_content <- paste(
  "## Contributors",
  "",
  "| Developer | Changes |",
  "|---|---|",
  "| Kaiping Yang | Promoted the Flexible Figure module to production |",
  "| Hao Wan | AE SOC/PT-by-Grade layout fix |",
  "| Yusi Liu | Flexible Figure module design and implementation |",
  "| Cheng Zhang | PC Summary table timepoint display fix |",
  sep = "\n"
)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
  on_chunk("writing contributors...\n")
  on_tool_call(
    "write-md-live",
    "Write",
    list(file_path = "CONTRIBUTORS.md", content = md_content),
    annotations = list(defaultOpen = TRUE)
  )
  on_tool_result("write-md-live", "File written", is_error = FALSE)
  on_done()
}

ui <- assistantUIPage(
  div(style = "width: 680px;", assistantUIOutput("chat", height = "82vh"))
)

server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      history_content <- sub("Kaiping Yang", "Historical Author", md_content, fixed = TRUE)
      args <- list(file_path = "HISTORICAL.md", content = history_content)
      send_thread(messages = list(
        list(
          id = "write-md-history-user",
          role = "user",
          content = list(list(type = "text", text = "Historical Markdown Write"))
        ),
        list(
          id = "write-md-history-assistant",
          role = "assistant",
          status = list(type = "complete", reason = "stop"),
          content = list(
            list(
              type = "tool-call",
              toolCallId = "write-md-history-tool",
              toolName = "Write",
              args = args,
              argsText = as.character(jsonlite::toJSON(args, auto_unbox = TRUE)),
              result = "File written",
              isError = FALSE,
              artifact = list(defaultOpen = TRUE)
            ),
            list(type = "text", text = "Historical Markdown Write restored")
          )
        )
      ), has_more = FALSE)
    }
  )

  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(
        id = "write-md-history",
        title = "Markdown Write history",
        preview = "Historical Markdown Write",
        createdAt = as.numeric(Sys.time()) * 1000
      )
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
