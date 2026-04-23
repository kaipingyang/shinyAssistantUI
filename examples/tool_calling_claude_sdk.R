library(shiny)
library(ClaudeAgentSDK)
devtools::load_all(here::here())

# ── ClaudeSDKClient 池（每线程一个，持久连接）────────────────────────────────
# permission_prompt_tool_name = "stdio" 将工具权限请求以 PermissionRequestMessage
# 形式路由到消息流，而非系统弹窗。
clients <- list()

get_client <- function(thread_id) {
  if (!is.null(clients[[thread_id]])) return(clients[[thread_id]])
  client <- ClaudeSDKClient$new(ClaudeAgentOptions(
    permission_mode             = "default",
    permission_prompt_tool_name = "stdio"
  ))
  client$connect()
  clients[[thread_id]] <<- client
  client
}

# ── 辅助：50ms 延迟 promise（poll 间隔）──────────────────────────────────────
later_promise <- function(delay = 0.05) {
  promises::promise(function(resolve, reject) {
    later::later(function() resolve(NULL), delay = delay)
  })
}

# ── handler ──────────────────────────────────────────────────────────────────
# 与 ellmer 版本的核心区别：coro::await(wait_for_approval(...)) 在 handler
# coroutine 顶层执行（非嵌套在 on_tool_request 回调内），用于排查嵌套深度问题。
handler <- coro::async(function(
  message, thread_id,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result,
  is_cancelled, wait_for_approval
) {
  client <- tryCatch(
    get_client(thread_id),
    error = function(e) { on_error(conditionMessage(e)); NULL }
  )
  if (is.null(client)) return(invisible(NULL))

  client$send(message)

  repeat {
    if (is_cancelled()) {
      client$interrupt()
      break
    }

    msgs <- client$poll_messages()

    done <- FALSE
    for (msg in msgs) {
      if (inherits(msg, "AssistantMessage")) {
        for (blk in msg$content) {
          if (inherits(blk, "TextBlock") && nzchar(blk$text)) {
            on_chunk(blk$text)
          }
        }
      } else if (inherits(msg, "PermissionRequestMessage")) {
        on_tool_call(
          tool_call_id = msg$request_id,
          tool_name    = msg$tool_name,
          args         = msg$tool_input,
          annotations  = list(requiresApproval = TRUE)
        )

        approved <- coro::await(wait_for_approval(msg$request_id))

        if (approved) {
          client$approve_tool(msg$request_id)
          on_tool_result(msg$request_id, "Approved", is_error = FALSE)
        } else {
          client$deny_tool(msg$request_id)
          on_tool_result(msg$request_id, "Denied by user", is_error = TRUE)
        }
      } else if (inherits(msg, "ResultMessage")) {
        done <- TRUE
        break
      }
    }

    if (done) break
    coro::await(later_promise(0.05))
  }

  on_done()
})

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML("
    html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }
  "))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ───────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE,

    suggestions = list(
      list(
        prompt = "List the files in the current directory using bash",
        text   = "List files (needs approval)"
      ),
      list(
        prompt = "Show the current date and time using bash",
        text   = "Show date/time (needs approval)"
      )
    )
  )
}

shinyApp(ui, server)
