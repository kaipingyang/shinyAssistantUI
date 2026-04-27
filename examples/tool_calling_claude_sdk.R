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
    permission_prompt_tool_name = "stdio",
    include_partial_messages    = TRUE
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
  message, thread_id, attachments,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, on_thinking,
  is_cancelled, wait_for_approval
) {
  client <- tryCatch(
    get_client(thread_id),
    error = function(e) { on_error(conditionMessage(e)); NULL }
  )
  if (is.null(client)) return(invisible(NULL))

  # 处理附件：图片 + 文本文件
  atts <- attachments %||% list()

  # 图片附件
  img_parts <- lapply(
    Filter(function(a) identical(a$type, "image"), atts),
    function(a) a$data  # data URL 直接可用
  )

  # 文本附件合并到消息体
  text_sections <- paste(
    vapply(Filter(function(a) identical(a$type, "text"), atts),
           function(a) a$data,  # 已含 <attachment> 包裹，直接使用
           character(1)),
    collapse = "\n"
  )
  if (nzchar(text_sections)) {
    full_message <- paste0(text_sections, "\n\n", message)
  } else {
    full_message <- message
  }

  # 发送消息 + 图片（ClaudeAgentSDK 多模态）
  if (length(img_parts) > 0) {
    client$send_with_images(full_message, img_parts)
  } else {
    client$send(full_message)
  }

  # StreamEvent 包含 Anthropic 原始 SSE 事件，可流式输出 thinking 和 text。
  # AssistantMessage 是完整消息，text/thinking 已通过 StreamEvent 处理，跳过避免重复。
  repeat {
    if (is_cancelled()) {
      client$interrupt()
      break
    }

    msgs <- client$poll_messages()

    done <- FALSE
    for (msg in msgs) {
      if (inherits(msg, "StreamEvent")) {
        evt   <- msg$event
        delta <- evt[["delta"]]
        if (identical(evt[["type"]], "content_block_delta") && is.list(delta)) {
          if (identical(delta[["type"]], "thinking_delta") && nzchar(delta[["thinking"]] %||% "")) {
            on_thinking(delta[["thinking"]])
          } else if (identical(delta[["type"]], "text_delta") && nzchar(delta[["text"]] %||% "")) {
            on_chunk(delta[["text"]])
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
    coro::await(later_promise(0.01))
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

    # action_items：点击后触发 on_action(id)，不发消息给模型
    action_items = list(
      list(section = "Model",    id = "thinking-on",   label = "Enable thinking",
           description = "Turn on extended thinking mode"),
      list(section = "Model",    id = "thinking-off",  label = "Disable thinking",
           description = "Turn off extended thinking mode"),
      list(section = "Settings", id = "clear-history", label = "Clear history",
           description = "Clear all stored conversations"),
      list(section = "Support",  id = "view-docs",     label = "View help docs",
           description = "Open shinyAssistantUI documentation")
    ),

    on_action = function(id) {
      if (id == "clear-history") {
        # localStorage 数据由浏览器端持有，R 无法直接清除；
        # 可发送 clear 信号新建线程，彻底刷新则需用户手动清除浏览器缓存。
        session$sendCustomMessage(paste0("chat_input:clear"), list())
      } else if (id == "view-docs") {
        session$sendCustomMessage("shiny-notification-show", list(
          message = "shinyAssistantUI: https://github.com/kaipingyang/shinyAssistantUI",
          type    = "message",
          duration = 5
        ))
      }
      # thinking-on / thinking-off: 可在此修改传给 handler 的系统提示或模型参数
    },

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
