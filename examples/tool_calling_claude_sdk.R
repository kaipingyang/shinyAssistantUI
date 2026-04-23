library(shiny)
library(ClaudeAgentSDK)
devtools::load_all(here::here())

# ── ClaudeSDKClient 池（每线程一个，持久连接）────────────────────────────────
# permission_prompt_tool_name = "stdio" 将工具权限请求以 PermissionRequestMessage
# 形式路由到消息流，而非系统弹窗，从而可在 UI 卡片上触发 Approve/Deny。
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

# ── 辅助：poll 延迟 promise ───────────────────────────────────────────────────
later_promise <- function(delay = 0.05) {
  promises::promise(function(resolve, reject) {
    later::later(function() resolve(NULL), delay = delay)
  })
}

# ── handler ──────────────────────────────────────────────────────────────────
handler <- coro::async(function(
  message, thread_id,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, on_thinking,
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
          if (inherits(blk, "ThinkingBlock") && nzchar(blk$thinking)) {
            on_thinking(blk$thinking)
          } else if (inherits(blk, "TextBlock") && nzchar(blk$text)) {
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

# ── 动态加载 Claude Code skills（project + global + plugins）─────────────────
# load_claude_skills() 扫描 .claude/commands/ 目录下的 .md 文件：
#   优先级：project > global (~/.claude/commands/) > plugins
# 注意：/model、/resume 等 Claude Code CLI 内建命令不存在于文件中，无法加载。
skills <- load_claude_skills(project_dir = here::here())

# ── Server ───────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE,

    suggestions = list(
      list(
        prompt = "List the files in the current directory using bash",
        text   = "List files"
      ),
      list(
        prompt = "Show the current git status",
        text   = "Git status"
      ),
      list(
        prompt = "Show the current date and time using bash",
        text   = "Show date/time"
      ),
      list(
        prompt = "What tools and capabilities do you have? Please list them with examples.",
        text   = "What can you do?"
      )
    ),

    commands = skills,

    tools = list(
      list(name = "Bash",     description = "Execute shell commands"),
      list(name = "Read",     description = "Read file contents"),
      list(name = "Write",    description = "Write files"),
      list(name = "Edit",     description = "Edit existing files"),
      list(name = "Glob",     description = "Find files by pattern"),
      list(name = "Grep",     description = "Search in files"),
      list(name = "WebFetch", description = "Fetch content from a URL"),
      list(name = "LS",       description = "List directory contents")
    )
  )
}

shinyApp(ui, server)
