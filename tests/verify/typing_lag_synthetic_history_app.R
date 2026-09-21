library(shiny)
library(shinyAssistantUI)
library(ClaudeAgentSDK)

# 诊断实验:重启后加载一个大历史 session、点几次 Refresh、再打字是否卡顿。
# 用合成消息(不走真实 SDK 调用),隔离出"历史消息挂载量"这一个变量。
n_messages <- as.integer(Sys.getenv("SYNTH_HISTORY_N", "300"))
# "mixed" = 1/3 user + 1/3 tool-call + 1/3 assistant(默认,贴近真实会话)
# "text"  = 全部纯文本消息,用来分离"消息条数"与"tool-call 卡片"各自的代价
history_kind <- Sys.getenv("SYNTH_HISTORY_KIND", "mixed")

make_history <- function(n) {
  msgs <- list()
  for (i in seq_len(n)) {
    is_tool <- identical(history_kind, "mixed") && i %% 3 == 2
    if (i %% 3 == 1) {
      msgs[[length(msgs) + 1L]] <- list(
        id = sprintf("h-user-%d", i), role = "user",
        content = list(list(type = "text", text = sprintf(
          "这是第 %d 条历史用户消息,用来撑起真实会话里常见的长度和格式。", i)))
      )
    } else if (is_tool) {
      msgs[[length(msgs) + 1L]] <- list(
        id = sprintf("tool-h-%d", i), role = "assistant",
        content = list(list(
          type = "tool-call", toolCallId = sprintf("call-%d", i),
          toolName = "Bash", args = list(command = sprintf("echo step-%d", i)),
          argsText = sprintf("{\"command\":\"echo step-%d\"}", i),
          result = paste(rep("output line", 20), collapse = "\n"),
          isError = FALSE
        ))
      )
    } else {
      msgs[[length(msgs) + 1L]] <- list(
        id = sprintf("h-assistant-%d", i), role = "assistant",
        content = list(list(type = "text", text = sprintf(
          "这是第 %d 条历史助手回复,包含一些解释性文字,模拟真实对话长度。", i))),
        status = list(type = "complete", reason = "stop")
      )
    }
  }
  msgs
}

synthetic_history <- make_history(n_messages)

handler <- make_claude_handler(
  options = ClaudeAgentOptions(include_partial_messages = TRUE,
                               permission_mode = "bypassPermissions")
)

session_loader <- function(session_id, thread_id, send_thread, cursor = NULL, limit = 50L) {
  cat("SESSION_LOADER_CALLED session_id=", session_id, " thread_id=", thread_id, "\n", sep = "")
  send_thread(messages = synthetic_history, cursor = NULL, has_more = FALSE)
  cat("SESSION_LOADER_SENT n=", length(synthetic_history), "\n", sep = "")
}

ui <- fluidPage(assistantUIOutput("chat", height = "100vh"))
server <- function(input, output, session) {
  controls <- assistantUIServer("chat", handler = handler,
                                on_session_load = session_loader,
                                show_thread_list = TRUE)
  session$onFlushed(function() {
    controls$send_sessions(list(sessions = list(list(
      id = "synthetic-big-history",
      title = "Synthetic Big History",
      preview = sprintf("%d messages", n_messages),
      createdAt = "2026-09-17T00:00:00Z"
    ))))
  }, once = TRUE)
}
shinyApp(ui, server)
