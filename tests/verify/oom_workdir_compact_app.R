library(shiny)
library(promises)

verify_lib <- Sys.getenv(
  "SHINYASSISTANTUI_VERIFY_LIB",
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
)
library(shinyAssistantUI, lib.loc = verify_lib)

ui_result <- getFromNamespace(".claude_ui_tool_result", "shinyAssistantUI")
msgs_to_thread <- getFromNamespace(".claude_msgs_to_thread", "shinyAssistantUI")

ui <- assistantUIPage(
  tags$head(tags$link(rel = "icon", href = "data:,")),
  tags$div(
    style = "position:fixed;left:-10000px;top:-10000px",
    textOutput("picker_count", inline = TRUE),
    textOutput("fixture_package", inline = TRUE)
  ),
  assistantUIOutput("chat", height = "100%")
)

server <- function(input, output, session) {
  picker_count <- reactiveVal(0L)
  output$picker_count <- renderText(picker_count())
  output$fixture_package <- renderText(paste0(
    "installed-", as.character(packageVersion("shinyAssistantUI"))
  ))

  handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result, ...) {
    on_tool_call(
      tool_call_id = "live-large-result",
      tool_name = "Bash",
      args = list(command = "synthetic-large-output"),
      annotations = list(defaultOpen = TRUE)
    )
    on_tool_result(
      tool_call_id = "live-large-result",
      result = ui_result(strrep("L", 2L * 1024L * 1024L)),
      is_error = FALSE
    )
    promises::promise(function(resolve, reject) {
      later::later(function() {
        on_chunk("RUN COMPLETED")
        on_done()
        resolve(NULL)
      }, delay = 2)
    })
  }

  controller <- assistantUIServer(
    "chat",
    handler = handler,
    persistence = "server",
    show_thread_list = TRUE,
    working_dir = "/tmp/native-picker-fixture",
    native_picker = TRUE,
    on_pick_working_dir = function() {
      picker_count(picker_count() + 1L)
      invisible(NULL)
    },
    on_session_load = function(session_id, thread_id, send_thread, ...) {
      raw_messages <- list(
        list(
          type = "user", uuid = "compact-browser",
          is_compact_summary = TRUE,
          is_visible_in_transcript_only = TRUE,
          message = list(role = "user", content = "BROWSER COMPACT SUMMARY")
        ),
        list(
          type = "user", uuid = "tool-result-browser",
          message = list(role = "user", content = list(list(
            type = "tool_result", tool_use_id = "history-large-result",
            content = strrep("H", 2L * 1024L * 1024L), is_error = FALSE
          )))
        ),
        list(
          type = "assistant", uuid = "tool-call-browser",
          message = list(role = "assistant", content = list(list(
            type = "tool_use", id = "history-large-result", name = "Bash",
            input = list(command = "synthetic-history-output")
          )))
        )
      )
      send_thread(messages = msgs_to_thread(raw_messages), has_more = FALSE)
    }
  )

  session$onFlushed(function() {
    controller$send_sessions(list(sessions = list(list(
      id = "22222222-2222-2222-2222-222222222222",
      title = "Compact and large history",
      preview = "BROWSER COMPACT SUMMARY",
      createdAt = as.numeric(Sys.time()) * 1000
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
