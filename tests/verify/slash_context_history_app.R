suppressPackageStartupMessages({
  library(shiny)
  library(shinyAssistantUI)
})

warmed_threads <- new.env(parent = emptyenv())

handler <- function(message, thread_id, on_chunk, on_done, on_warming, ...) {
  if (!isTRUE(get0(thread_id, envir = warmed_threads, inherits = FALSE))) {
    on_warming(TRUE)
    Sys.sleep(0.6)
    assign(thread_id, TRUE, envir = warmed_threads)
    on_warming(FALSE)
  }
  on_chunk(sprintf("ECHO[%s]", message))
  on_done()
}

attr(handler, "warmup") <- function(thread_id) {
  Sys.sleep(0.7)
  assign(thread_id, TRUE, envir = warmed_threads)
  invisible(NULL)
}

attr(handler, "action_handler") <- function(id, thread_id, send_action_result) {
  if (identical(id, "context")) {
    send_action_result(paste(
      "# Context Usage",
      "",
      "**Model:** `fixture-sonnet`",
      "**Tokens:** 12.3k / 200k (6.2%)",
      "",
      "## Estimated usage by category",
      "",
      "| Category | Tokens | Percentage |",
      "| --- | ---: | ---: |",
      "| System prompt | 1.2k | 0.6% |",
      "",
      "## Memory Files",
      "",
      "| Type | Path | Tokens |",
      "| --- | --- | ---: |",
      "| Project | CLAUDE.md | 42 |",
      sep = "\n"
    ))
  } else {
    send_action_result(sprintf("Unknown action: %s", id), status = "error")
  }
}

ui <- fluidPage(
  tags$style("html, body, .container-fluid { height: 100%; margin: 0; padding: 0; }"),
  assistantUIOutput("chat", height = "100vh")
)

server <- function(input, output, session) {
  controls <- assistantUIServer(
    "chat",
    handler = handler,
    show_thread_list = TRUE,
    prewarm = FALSE,
    commands = c(
      list(
        list(
          name = "yourskill",
          description = "Fixture project skill",
          prompt = "/yourskill",
          category = "Project Skills"
        )
      ),
      lapply(seq_len(14L), function(index) list(
        name = sprintf("scrollcmd%02d", index),
        description = sprintf("Fixture scroll command %02d", index),
        prompt = sprintf("/scrollcmd%02d", index),
        category = "Project Skills"
      ))
    ),
    action_items = list(
      list(
        section = "Actions",
        id = "context",
        command = "context",
        label = "Context",
        description = "Show complete context usage"
      )
    ),
    persistence = "server",
    on_session_load = local({
      # 通过真实 .claude_msgs_to_thread 处理一段原始 SDK 形状消息（含 resume 时以 user 轮次
      # 写入的 <task-notification> 合成通知），端到端验证显示层过滤：真实 user/assistant 保留，
      # task-notification 不渲染为气泡。
      synthetic_checked <- shinyAssistantUI:::.claude_msgs_to_thread(list(
        list(type = "user", uuid = "real-before",
             message = list(content = "REAL_USER_BEFORE_NOTIF")),
        list(type = "user", uuid = "orphan-notif",
             message = list(content = list(list(type = "text", text = paste0(
               "<task-notification>\n<task-id>b4f7icfpc</task-id>\n",
               "<task-id>bbrdq2z1c</task-id>\n<status>stopped</status>\n",
               "<summary>2 background shell command task(s) stopped.</summary>\n",
               "</task-notification>"
             ))))),
        list(type = "assistant", uuid = "real-after",
             message = list(content = list(list(type = "text", text = "REAL_ASSISTANT_AFTER_NOTIF"))))
      ))
      historical_messages <- c(
        lapply(seq_len(60L), function(index) list(
          id = sprintf("history-old-%03d", index),
          role = "user",
          content = list(list(
            type = "text",
            text = sprintf("OLDER_FIXTURE_%03d", index)
          ))
        )),
        list(
          list(
            id = "history-user",
            role = "user",
            content = list(list(type = "text", text = "HISTORICAL_FIXTURE_MESSAGE"))
          ),
          list(
            id = "history-tool",
            role = "assistant",
            content = list(list(
              type = "tool-call",
              toolCallId = "history-tool-1",
              toolName = "Read",
              args = list(file_path = "fixture.R"),
              argsText = '{"file_path":"fixture.R"}',
              result = "fixture tool result"
            ))
          )
        ),
        synthetic_checked
      )
      function(session_id, thread_id, send_thread, cursor = NULL, limit = 50L) {
        if (is.null(cursor)) Sys.sleep(0.35)
        upper <- if (is.null(cursor)) length(historical_messages) else as.integer(cursor)
        lower <- max(1L, upper - as.integer(limit) + 1L)
        next_cursor <- lower - 1L
        send_thread(
          historical_messages[seq.int(lower, upper)],
          cursor = if (next_cursor > 0L) next_cursor else NULL,
          has_more = next_cursor > 0L
        )
      }
    })
  )

  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(list(
      id = "fixture-history-session",
      title = "Fixture History",
      preview = "Historical fixture",
      createdAt = "2026-07-01T00:00:00Z"
    ))))
  }, once = TRUE)
}

shinyApp(ui, server)
