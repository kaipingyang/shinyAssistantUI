# Fixture: generic Markdown ToolView for ExitPlanMode and Write, live approval + history.
library(shiny)
library(shinyAssistantUI)

md_content <- paste(
  "## Contributors",
  "",
  "| Developer | Changes |",
  "|---|---|",
  "| Kaiping Yang | Promoted the Flexible Figure module to production |",
  "| Hao Wan | AE SOC/PT-by-Grade layout fix |",
  sep = "\n"
)
plan_content <- paste(
  "## Live plan",
  "",
  "| Step | State |",
  "|---|---|",
  "| Test | Ready |",
  sep = "\n"
)

handler <- function(message, on_chunk, on_done, on_tool_call, on_tool_result,
                    wait_for_approval, ...) {
  on_chunk("preparing plan and contributors...\n")
  on_tool_call(
    "exit-plan-live",
    "ExitPlanMode",
    list(plan = plan_content, planFilePath = "/custom/location/live-plan.txt"),
    annotations = list(defaultOpen = TRUE)
  )
  on_tool_result("exit-plan-live", "Plan ready", is_error = FALSE)

  write_args <- list(file_path = "arbitrary/nested/CONTRIBUTORS.md", content = md_content)
  on_tool_call(
    "write-md-live",
    "Write",
    write_args,
    annotations = list(
      defaultOpen = TRUE,
      requiresApproval = TRUE,
      title = "Write contributors Markdown"
    )
  )
  promises::then(wait_for_approval("write-md-live"), function(decision) {
    preserved <- identical(write_args$file_path, "arbitrary/nested/CONTRIBUTORS.md") &&
      identical(write_args$content, md_content)
    if (isTRUE(decision$approved)) {
      on_tool_result("write-md-live", "File written", is_error = FALSE)
      on_chunk(if (preserved) "ORIGINAL_ARGS_PRESERVED" else "ORIGINAL_ARGS_CHANGED")
    } else {
      on_tool_result("write-md-live", "Write denied", is_error = TRUE)
    }
    on_done()
  })
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
      history_plan <- sub("Live plan", "Historical plan", plan_content, fixed = TRUE)
      plan_args <- list(
        plan = history_plan,
        planFilePath = "D:\\custom\\plans\\history.anything"
      )
      write_args <- list(
        path = "D:\\custom\\docs\\HISTORICAL.MARKDOWN",
        content = history_content
      )
      send_thread(messages = list(
        list(
          id = "write-md-history-user",
          role = "user",
          content = list(list(type = "text", text = "Historical Markdown tools"))
        ),
        list(
          id = "write-md-history-assistant",
          role = "assistant",
          status = list(type = "complete", reason = "stop"),
          content = list(
            list(
              type = "tool-call",
              toolCallId = "exit-plan-history-tool",
              toolName = "ExitPlanMode",
              args = plan_args,
              argsText = as.character(jsonlite::toJSON(plan_args, auto_unbox = TRUE)),
              result = "Plan ready",
              isError = FALSE,
              artifact = list(defaultOpen = TRUE)
            ),
            list(
              type = "tool-call",
              toolCallId = "write-md-history-tool",
              toolName = "Write",
              args = write_args,
              argsText = as.character(jsonlite::toJSON(write_args, auto_unbox = TRUE)),
              result = "File written",
              isError = FALSE,
              artifact = list(defaultOpen = TRUE)
            ),
            list(type = "text", text = "Historical Markdown tools restored")
          )
        )
      ), has_more = FALSE)
    }
  )

  session$onFlushed(function() {
    ctrl$send_sessions(list(sessions = list(
      list(
        id = "write-md-history",
        title = "Markdown tools history",
        preview = "Historical Markdown tools",
        createdAt = as.numeric(Sys.time()) * 1000
      )
    )))
  }, once = TRUE)
}

shinyApp(ui, server)
