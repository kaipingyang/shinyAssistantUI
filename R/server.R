#' Assistant UI Server Module
#'
#' Handles the server-side logic for an [assistantUIOutput()] widget: receives
#' user messages, calls a backend handler, and streams responses back to the UI.
#'
#' @param id The module ID matching the `outputId` passed to [assistantUIOutput()].
#' @param handler A function with signature
#'   `function(message, thread_id, on_chunk, on_done, on_error,
#'              on_tool_call, on_tool_result, is_reload)` where:
#'   * `message` — character string of the user's message.
#'   * `thread_id` — character string identifying the current thread (for
#'     multi-turn conversation routing).
#'   * `on_chunk(text)` — call repeatedly to stream response tokens.
#'   * `on_done()` — call once when the response is complete.
#'   * `on_error(msg)` — call to surface an error in the UI.
#'   * `on_tool_call(tool_call_id, tool_name, args, annotations)` — show a
#'     tool call card. `args` should be a named list. `annotations` is an
#'     optional named list controlling card appearance and result rendering.
#'     Recognized keys:
#'     * `icon` — lucide icon name (`"search"`, `"database"`, `"code"`, …)
#'     * `title` — display name shown in the card header
#'     * `requiresApproval` — `TRUE` to show Approve/Deny buttons
#'     * `resultType` — how to render the result from `on_tool_result()`:
#'       `"auto"` (default, JSON/text in `<pre>`), `"markdown"`,
#'       `"table"`, `"code"`, `"image"`, `"file"`, `"html"`
#'     * `resultLang` — language for `resultType = "code"` (e.g. `"r"`,
#'       `"python"`, `"sql"`; default `"text"`)
#'     * `resultFilename` — filename for `resultType = "file"` download
#'       button (e.g. `"results.csv"`; default `"download"`)
#'   * `on_tool_result(tool_call_id, result, is_error = FALSE)` — update the
#'     tool card with the result.
#'     - `resultType = "table"`: pass `jsonlite::toJSON(df, auto_unbox = FALSE)`
#'     - `resultType = "file"`: pass base64 data URL
#'       (`paste0("data:text/csv;base64,", jsonlite::base64_enc(chartr(...)))`)
#'     - `resultType = "html"`: pass HTML string (rendered via
#'       `dangerouslySetInnerHTML`; only use with trusted tool output)
#'   * `attachments` — list of named lists, one per file the user attached.
#'     Each element has `type` (`"image"`, `"text"`, or `"file"`), `name`
#'     (filename), `data` (data-URL string for images, plain text for text
#'     files, base64 for other files), and optionally `contentType` (MIME
#'     type). Empty list `list()` when no attachments are present.
#'   * `is_reload` — `TRUE` when the user clicked "regenerate"; the handler
#'     receives the same `message` text and can remove the previous assistant
#'     turn from the LLM history before re-running.
#'   * `is_cancelled` — zero-argument function that returns `TRUE` once the
#'     user has clicked the stop button. Poll this inside your streaming loop
#'     to implement true server-side cancellation:
#'     ```r
#'     for (chunk in stream) {
#'       if (is_cancelled()) break
#'       on_chunk(chunk)
#'     }
#'     on_done()
#'     ```
#'     For [ClaudeAgentSDK](https://github.com/kaipingyang/ClaudeAgentSDK),
#'     call `client$interrupt()` when `is_cancelled()` returns `TRUE`.
#'   * `wait_for_approval` — `function(tool_call_id)` that returns a
#'     `promises::promise` which resolves to `TRUE` (approved) or `FALSE`
#'     (denied) once the user clicks Approve/Deny in the tool card UI.
#'     Use inside a `coro::async` `on_tool_request` callback to pause
#'     the stream until human approval:
#'     ```r
#'     chat$on_tool_request(coro::async(function(request) {
#'       on_tool_call(request@id, request@name, request@arguments,
#'                   list(requiresApproval = TRUE))
#'       approved <- coro::await(wait_for_approval(request@id))
#'       if (!approved) ellmer::tool_reject("User denied the tool call.")
#'     }))
#'     ```
#'
#'   * `register_cancel` — `function(fn)` that stores a cancel callback for
#'     the current thread. Call once before starting the stream with a function
#'     that performs true HTTP cancellation (e.g.
#'     `register_cancel(function() ctrl$cancel("Interrupted"))`).  When the
#'     user clicks Stop, `assistantUIServer` calls `fn()` immediately so the
#'     in-flight HTTP request is closed rather than silently drained.
#'
#'   All parameters except `message`, `on_chunk`, `on_done`, and `on_error`
#'   are optional: handlers that omit them continue to work unchanged.
#'
#'   The handler may return a promise (from `promises` or `coro`) for async
#'   streaming; errors from the promise are automatically forwarded via
#'   `on_error`.
#' @param show_thread_list Logical. If `TRUE`, a thread list sidebar is shown
#'   inside the widget for switching between conversations. Default `FALSE`
#'   (backward-compatible).
#' @param suggestions List of starter suggestion bubbles shown before the first
#'   message. Each element is a list with `prompt` (required, the text sent on
#'   click) and optional `text` (display label, defaults to `prompt`).
#' @param commands List of slash-command definitions. Each element is a list
#'   with `name` (e.g. `"summarize"`), `description`, `prompt` (the message
#'   sent immediately when the command is selected), and optional `category`
#'   (group label shown as a section header in the popover). Category should be
#'   one of the 6 fixed sections: `"Context"`, `"Model"`, `"Customize"`,
#'   `"Slash Commands"` (default), `"Settings"`, `"Support"`.
#' @param action_items List of action-type slash-command items. Unlike
#'   `commands`, these do not send a message to the AI — instead, clicking them
#'   fires `on_action(id)` on the R side, allowing arbitrary server logic.
#'   Each element is a list with `section` (one of the 6 fixed section names),
#'   `id` (unique string passed to `on_action`), `label` (display name), and
#'   optional `description`. Example:
#'   ```r
#'   action_items = list(
#'     list(section = "Model",   id = "thinking-on",  label = "Enable thinking"),
#'     list(section = "Support", id = "view-docs",    label = "View help docs",
#'          description = "Open documentation")
#'   )
#'   ```
#' @param on_action `function(id)` called when the user clicks an item from
#'   `action_items`. `id` is the string from the item definition. Use this to
#'   trigger server-side logic (e.g. toggle a setting, open a URL, call
#'   `clear()`). `NULL` (default) means no handler is registered.
#' @param tools List of tool definitions for the \@ mention menu. Each element
#'   is a list with `name` and `description`. Typically mirrors the tools
#'   registered with ellmer.
#' @param code_theme Character string selecting the syntax-highlighting theme
#'   for code blocks. Available light themes: `"one-light"` (default),
#'   `"ghcolors"`, `"vs"`, `"solarized-light"`. Available dark themes:
#'   `"vsc-dark-plus"`, `"dracula"`, `"nord"`, `"night-owl"`, `"one-dark"`.
#' @param strings Optional named list for overriding UI text (tooltips, labels,
#'   placeholders). `NULL` (default) keeps all built-in English strings. Example
#'   for a Chinese UI:
#'   ```r
#'   strings = list(
#'     assistantMessage = list(
#'       copy   = list(tooltip = "复制"),
#'       reload = list(tooltip = "重新生成")
#'     ),
#'     editComposer = list(
#'       send   = list(label = "发送"),
#'       cancel = list(label = "取消")
#'     )
#'   )
#'   ```
#'
#' @param assistant_avatar Named list controlling the assistant's avatar.
#'   Fields: `fallback` (1–2 character string or emoji shown when no image is
#'   set), `src` (URL to an image), `alt` (alt text). Defaults to
#'   `list(fallback = "AI")`. Example with custom image:
#'   ```r
#'   assistant_avatar = list(src = "https://example.com/logo.png", fallback = "AI")
#'   ```
#' @param on_session_load Optional `function(session_id, thread_id, send_thread)`
#'   called when the frontend requests messages for a historical session thread.
#' @param on_feedback Optional `function(message_id, type)` called when the user
#'   clicks a 👍/👎 feedback button (`type` is `"positive"` or `"negative"`).
#' @param modal Logical. If `TRUE`, renders the chat as a floating modal bubble
#'   instead of an inline panel.
#' @param prewarm Logical (default `TRUE`). If the `handler` exposes a `warmup`
#'   attribute (e.g. [make_claude_handler()]), pre-connect the initial thread's
#'   client on mount so the **first** message on that thread isn't slowed by the
#'   cold start (ClaudeSDKClient spawning the `claude` CLI subprocess). A brief
#'   cold-start indicator is shown while connecting. New threads / loaded sessions
#'   still cold-start on their first message (indicator shown). Set `FALSE` to
#'   avoid eagerly spawning a subprocess (e.g. resource-sensitive multi-user apps).
#' @param on_rename Optional `function(thread_id, title)` called when the user
#'   renames a thread in the sidebar. The new title is already persisted
#'   client-side (localStorage); use this to sync server-side session stores.
#' @param theme Optional named list of theme tokens to recolor the widget, e.g.#'   from [assistant_theme()]. Colors may be hex/named/`rgb()` strings and are
#'   converted to assistant-ui's HSL-component format. Applied as scoped CSS
#'   variables on this widget only (multiple widgets can have different themes).
#'   Example: `theme = assistant_theme(primary = "#2563eb")`.
#' @param dark_mode Dark color scheme control: `FALSE` (light, default), `TRUE`
#'   (dark), or `"auto"` (follow the OS/browser `prefers-color-scheme`). A custom
#'   `theme` overrides individual tokens in either mode.
#' @param show_timestamps Logical. If `TRUE`, each user/assistant message shows
#'   its send time (HH:MM), derived from the message id. Defaults to `FALSE`.
#'
#'   * `on_session_load` — `function(session_id, thread_id, send_thread)` called
#'     when the frontend requests historical messages for a session thread. Used
#'     with `send_sessions()` (in the return value) to populate the sidebar with
#'     Claude Code sessions and lazy-load their messages on click.
#'     * `session_id` — the Claude session UUID
#'     * `thread_id` — the UI thread ID (equals `session_id` for imported threads)
#'     * `send_thread(messages)` — call with a list of `ThreadMessageLike` objects
#'       (each a named list with `id`, `role`, `content` fields) to populate the
#'       thread.
#'
#' @return A list with a `clear()` function that creates a new thread in the UI,
#'   `send_tool_call()` / `send_tool_result()` for manual tool card control, and
#'   `send_sessions(sessions)` for injecting a list of historical session stubs
#'   into the sidebar (each element: named list with `id`, `title`, `preview`,
#'   `createdAt` fields).
#' @export
assistantUIServer <- function(id, handler,
                              show_thread_list  = FALSE,
                              suggestions       = list(),
                              commands          = list(),
                              tools             = list(),
                              action_items      = list(),
                              on_action         = NULL,
                              on_session_load   = NULL,
                              on_feedback       = NULL,
                              on_rename         = NULL,
                              code_theme        = "one-light",
                              strings           = NULL,
                              assistant_avatar  = list(fallback = "AI"),
                              theme             = NULL,
                              dark_mode         = FALSE,
                              show_timestamps   = FALSE,
                              modal             = FALSE,
                              prewarm           = TRUE) {
  force(show_thread_list); force(suggestions); force(commands)
  force(tools); force(action_items); force(on_action); force(on_session_load)
  force(on_feedback); force(modal)
  force(on_rename)
  # 若 handler 暴露了内置动作分发器(如 make_claude_handler 的 ClaudeSDKClient 控制操作)
  # 且用户未自定义 on_action,则自动接线,使 /model、/clear 等客户端动作开箱即用。
  if (is.null(on_action)) {
    .action_handler <- attr(handler, "action_handler")
    if (!is.null(.action_handler)) on_action <- .action_handler
  }
  force(code_theme); force(strings); force(assistant_avatar)
  force(theme); force(dark_mode)
  force(show_timestamps)
  session  <- shiny::getDefaultReactiveDomain()
  input_id <- paste0(id, "_input")

  # dark_mode 归一化:TRUE/FALSE/"auto"
  if (is.logical(dark_mode)) dark_mode <- isTRUE(dark_mode)
  else if (!identical(dark_mode, "auto"))
    stop("`dark_mode` must be TRUE, FALSE, or \"auto\".")

  config <- list(
    show_thread_list = show_thread_list,
    suggestions      = suggestions,
    commands         = commands,
    tools            = tools,
    action_items     = action_items,
    code_theme       = code_theme,
    dark_mode        = dark_mode,
    show_timestamps  = show_timestamps,
    modal            = modal
  )
  normalized_theme <- .normalize_theme(theme)
  if (!is.null(normalized_theme))  config$theme            <- normalized_theme
  if (!is.null(strings))          config$strings          <- strings
  if (!is.null(assistant_avatar)) config$assistant_avatar <- assistant_avatar

  session$output[[id]] <- renderAssistantUI(
    config   = config,
    outputId = id
  )

  # 每线程 cancel 标志（mutable environment，cancel 信号到达时设为 TRUE）
  cancel_flags <- new.env(parent = emptyenv())
  # 每线程注册的 cancel 函数（handler 注入，cancel 信号到达时立即调用）
  cancel_fns <- new.env(parent = emptyenv())

  # ── 消息回调工厂（按 thread_id 构建，消息携带 threadId 供 JS 路由）──────────
  # 旧版：静态回调，所有 thread 共用一个 callbacks slot，切 thread 时旧 handler
  # 的 onDone 会错误清掉新 thread 的 running 状态，旧消息也可能串入新 thread。
  # 新版：每次 ExtendedTask 启动时动态构建，消息携带 threadId，JS 按 threadId 路由。
  make_callbacks <- function(thread_id) {
    list(
      on_chunk = function(text) {
        session$sendCustomMessage(paste0(input_id, ":chunk"),
                                  list(text = text, threadId = thread_id))
      },
      on_done = function(suggestions = list()) {
        session$sendCustomMessage(paste0(input_id, ":done"),
                                  list(suggestions = suggestions, threadId = thread_id))
      },
      on_error_fn = function(msg) {
        session$sendCustomMessage(paste0(input_id, ":error"),
                                  list(message = msg, threadId = thread_id))
      },
      on_tool_call = function(tool_call_id, tool_name, args = list(), annotations = list()) {
        # 注入 inputId，使前端审批 UI 能定位到本 widget 实例的 approval handler
        # （多 widget 同页时模块级单例会串台，靠 inputId 路由隔离）。
        annotations$inputId <- input_id
        session$sendCustomMessage(
          paste0(input_id, ":tool-call"),
          list(
            toolCallId  = tool_call_id,
            toolName    = tool_name,
            args        = args,
            argsText    = as.character(jsonlite::toJSON(args, auto_unbox = TRUE, pretty = FALSE)),
            annotations = annotations,
            threadId    = thread_id
          )
        )
      },
      on_tool_call_start = function(tool_call_id, tool_name, annotations = list()) {
        session$sendCustomMessage(
          paste0(input_id, ":tool-call-start"),
          list(
            toolCallId  = tool_call_id,
            toolName    = tool_name,
            annotations = annotations,
            threadId    = thread_id
          )
        )
      },
      on_tool_call_delta = function(tool_call_id, delta) {
        session$sendCustomMessage(
          paste0(input_id, ":tool-call-delta"),
          list(toolCallId = tool_call_id, delta = delta, threadId = thread_id)
        )
      },
      on_tool_result = function(tool_call_id, result, is_error = FALSE) {
        session$sendCustomMessage(
          paste0(input_id, ":tool-result"),
          list(toolCallId = tool_call_id, result = result, isError = is_error, threadId = thread_id)
        )
      },
      on_thinking = function(text) {
        session$sendCustomMessage(paste0(input_id, ":thinking"),
                                  list(text = text, threadId = thread_id))
      },
      on_source = function(url, title = NULL, id = NULL) {
        session$sendCustomMessage(paste0(input_id, ":source"),
                                  list(url = url, title = title, id = id, threadId = thread_id))
      },
      on_image = function(image) {
        session$sendCustomMessage(paste0(input_id, ":image"),
                                  list(image = image, threadId = thread_id))
      },
      on_artifact = function(id, title, content, type = "markdown", lang = NULL) {
        session$sendCustomMessage(paste0(input_id, ":artifact"),
                                  list(id = id, title = title, type = type,
                                       content = content, lang = lang, threadId = thread_id))
      },
      # ── ClaudeAgentSDK 能力对齐 ────────────────────────────────────────────
      # #1 成本/用量:ResultMessage 的 total_cost_usd / tokens / turns / duration。
      on_usage = function(cost_usd = NULL, tokens = NULL, turns = NULL,
                          duration_ms = NULL, model = NULL) {
        session$sendCustomMessage(paste0(input_id, ":usage"),
                                  list(costUsd = cost_usd, tokens = tokens, turns = turns,
                                       durationMs = duration_ms, model = model,
                                       threadId = thread_id))
      },
      # #2 子agent/Task 进度:kind = "started" | "progress" | "notification"。
      on_task = function(task_id, kind, description = NULL, status = NULL,
                         tool_name = NULL, summary = NULL) {
        session$sendCustomMessage(paste0(input_id, ":task"),
                                  list(taskId = task_id, kind = kind, description = description,
                                       status = status, toolName = tool_name, summary = summary,
                                       threadId = thread_id))
      },
      # #3 限流告警。
      on_rate_limit = function(status = NULL, resets_at = NULL, utilization = NULL, type = NULL) {
        session$sendCustomMessage(paste0(input_id, ":rate-limit"),
                                  list(status = status, resetsAt = resets_at,
                                       utilization = utilization, type = type,
                                       threadId = thread_id))
      },
      # #4 系统状态行:subtype = status/thinking_tokens/init 等。
      on_status = function(status, text = NULL) {
        session$sendCustomMessage(paste0(input_id, ":status"),
                                  list(status = status, text = text, threadId = thread_id))
      },
      # #5 命令自动发现:get_server_info() 拉到的 CLI slash 命令 + output styles。
      on_commands = function(commands = list(), output_styles = list()) {
        session$sendCustomMessage(paste0(input_id, ":server-commands"),
                                  list(commands = commands, outputStyles = output_styles,
                                       threadId = thread_id))
      },
      # 每线程冷启动指示:client 首次连接(spawn CLI 子进程)期间 active=TRUE。
      on_warming = function(active) {
        session$sendCustomMessage(paste0(input_id, ":warming"),
                                  list(active = isTRUE(active), threadId = thread_id))
      }
    )
  }

  # ── tool 审批 ────────────────────────────────────────────────────────────────
  # wait_for_approval 用 observeEvent 驱动。
  # 关键：handler 必须通过 ExtendedTask 启动（见下方 stream_task），
  # 只有 ExtendedTask 才允许 Shiny reactive flush 在 coro::await 挂起期间运行；
  # 直接从 observeEvent 里启动 handler 则不会触发 reactive flush，导致审批 observer 死锁。
  # 每个 resolver 记录所属 thread_id，使 cancel 只否决本线程的挂起审批（多线程隔离）。
  approval_resolvers <- new.env(parent = emptyenv())

  shiny::observeEvent(session$input[[paste0(input_id, "_tool_approval")]], {
    msg <- session$input[[paste0(input_id, "_tool_approval")]]
    if (is.null(msg)) return()
    tid <- msg$toolCallId
    entry <- get0(tid, envir = approval_resolvers)
    if (!is.null(entry)) {
      rm(list = tid, envir = approval_resolvers)
      entry$fn(msg)  # 传回完整 msg，handler 自行解析
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # 工厂：绑定 thread_id，返回该线程专用的 wait_for_approval。
  make_wait_for_approval <- function(thread_id) {
    function(tool_call_id) {
      promises::promise(function(resolve, reject) {
        assign(tool_call_id, list(fn = resolve, thread = thread_id),
               envir = approval_resolvers)
      })
    }
  }

  # action_items 点击 → 通知 on_action 回调
  if (!is.null(on_action)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_action")]], {
      msg <- session$input[[paste0(input_id, "_action")]]
      if (is.null(msg)) return()
      tid <- msg$threadId
      # 向 UI 回传动作结果(更新 ack 气泡):send_action_result(message, status="ok"|"error")
      send_action_result <- function(message, status = "ok") {
        session$sendCustomMessage(paste0(input_id, ":action-result"),
                                  list(threadId = tid, message = message, status = status))
      }
      all_args <- list(id = msg$id, thread_id = tid, send_action_result = send_action_result)
      pars <- names(formals(on_action))
      call_args <- if ("..." %in% pars) all_args else all_args[names(all_args) %in% pars]
      do.call(on_action, call_args)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 反馈按钮（👍/👎）→ on_feedback 回调
  if (!is.null(on_feedback)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_feedback")]], {
      fb <- session$input[[paste0(input_id, "_feedback")]]
      if (is.null(fb)) return()
      on_feedback(fb$messageId, fb$type)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 线程重命名 → on_rename 回调（前端已本地持久化标题;此回调供 server 端
  # session 存储同步,如更新 SQLite 里的 session title）
  if (!is.null(on_rename)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_rename")]], {
      rn <- session$input[[paste0(input_id, "_rename")]]
      if (is.null(rn)) return()
      on_rename(rn$threadId, rn$title)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 独立 observer 监听 cancel 信号
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    if (is.null(msg)) return()
    tid <- msg$threadId %||% "default"
    assign(tid, TRUE, envir = cancel_flags)
    # 调用 handler 注册的 cancel fn（如 stream_controller$cancel()），实现真 HTTP 取消。
    cancel_fn <- get0(tid, envir = cancel_fns)
    if (!is.null(cancel_fn)) {
      rm(list = tid, envir = cancel_fns)
      tryCatch(cancel_fn(), error = function(e) NULL)
    }
    # 自动以 denied resolve 本线程挂起的 wait_for_approval promise，
    # 避免 handler 在 coro::await(wait_for_approval(...)) 处死锁。
    # 仅否决属于被取消线程的审批，不影响其它线程（多线程隔离）。
    for (key in ls(approval_resolvers)) {
      entry <- get0(key, envir = approval_resolvers)
      if (!is.null(entry) && identical(entry$thread, tid)) {
        rm(list = key, envir = approval_resolvers)
        tryCatch(entry$fn(list(approved = FALSE, toolCallId = key)), error = function(e) NULL)
      }
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # ── ExtendedTask：以 Shiny-aware 异步任务运行 handler ────────────────────────
  # ExtendedTask 让 Shiny 知道有长时任务在运行，允许 reactive flush 在 await 期间发生，
  # 从而 _tool_approval / _cancel 等 observer 可以正常触发。
  stream_task <- shiny::ExtendedTask$new(
    function(msg_text, thread_id, is_reload, attachments) {
      cbs <- make_callbacks(thread_id)
      is_cancelled <- function() isTRUE(get0(thread_id, envir = cancel_flags))
      register_cancel <- function(fn) assign(thread_id, fn, envir = cancel_fns)
      wait_for_approval <- make_wait_for_approval(thread_id)

      all_args <- list(
        message           = msg_text,
        thread_id         = thread_id,
        on_chunk          = cbs$on_chunk,
        on_done           = cbs$on_done,
        on_error          = cbs$on_error_fn,
        on_tool_call      = cbs$on_tool_call,
        on_tool_call_start = cbs$on_tool_call_start,
        on_tool_call_delta = cbs$on_tool_call_delta,
        on_tool_result    = cbs$on_tool_result,
        on_thinking       = cbs$on_thinking,
        on_source         = cbs$on_source,
        on_image          = cbs$on_image,
        on_artifact       = cbs$on_artifact,
        on_usage          = cbs$on_usage,
        on_task           = cbs$on_task,
        on_rate_limit     = cbs$on_rate_limit,
        on_status         = cbs$on_status,
        on_warming        = cbs$on_warming,
        on_commands       = cbs$on_commands,
        attachments       = attachments,
        is_reload         = is_reload,
        is_cancelled      = is_cancelled,
        wait_for_approval = wait_for_approval,
        register_cancel   = register_cancel
      )
      handler_params <- names(formals(handler))
      call_args <- if ("..." %in% handler_params) all_args
                   else all_args[names(all_args) %in% handler_params]

      result <- tryCatch(
        do.call(handler, call_args),
        error = function(e) { cbs$on_error_fn(conditionMessage(e)); NULL }
      )
      if (inherits(result, "promise")) {
        promises::catch(result, function(e) { cbs$on_error_fn(conditionMessage(e)); NULL })
      } else {
        promises::promise_resolve(NULL)
      }
    }
  )

  # ── sessions ready 握手：JS handler 注册后补发 sessions ────────────────────
  # React 18 createRoot().render() 是异步的，Shiny 首次 flush 时 :sessions
  # handler 尚未注册，消息被静默丢弃。JS ready 信号到达后，用缓存的 sessions 补发。
  pending_sessions <- NULL

  shiny::observeEvent(session$input[[paste0(input_id, "_sessions_ready")]], {
    if (!is.null(pending_sessions)) {
      session$sendCustomMessage(paste0(input_id, ":sessions"), pending_sessions)
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg)) return()
    # load_session 消息没有 text 字段，不能用 nzchar 过滤
    if (!identical(msg$type, "load_session") && !nzchar(trimws(msg$text %||% ""))) return()

    # load_session：前端请求某历史 session 的消息记录，不走 stream_task
    if (identical(msg$type, "load_session") && !is.null(on_session_load)) {
      send_thread <- function(messages) {
        session$sendCustomMessage(
          paste0(input_id, ":load-thread"),
          list(threadId = msg$threadId, messages = messages)
        )
      }
      on_session_load(msg$sessionId, msg$threadId, send_thread)
      return()
    }

    thread_id <- msg$threadId %||% "default"
    is_reload <- identical(msg$type, "reload")

    # 新 run 开始前重置 cancel 标志和 cancel fn
    assign(thread_id, FALSE, envir = cancel_flags)
    if (exists(thread_id, envir = cancel_fns)) rm(list = thread_id, envir = cancel_fns)

    stream_task$invoke(
      msg$text,
      thread_id,
      is_reload,
      msg$attachments %||% list()
    )
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # 预热:prewarm=TRUE 且 handler 暴露 warmup(如 make_claude_handler)时,JS 挂载会发来
  # 当前 threadId → 后台连接该线程的 client,使【首条消息】不再冷启动。复用冷启动指示器:
  # 嵌套 later 让 on_warming(TRUE) 先 flush(指示器渲染)再跑阻塞式 connect。仅初始线程一次。
  .warmup_fn <- attr(handler, "warmup")
  if (isTRUE(prewarm) && is.function(.warmup_fn)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_warmup")]], {
      msg <- session$input[[paste0(input_id, "_warmup")]]
      tid <- if (is.list(msg)) msg$threadId else NULL
      if (is.null(tid) || !nzchar(tid %||% "")) return()
      cbs <- make_callbacks(tid)
      later::later(function() {
        cbs$on_warming(TRUE)
        later::later(function() {
          tryCatch(.warmup_fn(tid), error = function(e) NULL)
          cbs$on_warming(FALSE)
        }, 0.05)
      }, 0.1)
    }, once = TRUE, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # session 结束时回收 handler 持有的资源（如 ClaudeSDKClient 子进程）。
  # handler 可选通过 attr(handler, "cleanup") 暴露清理函数；ellmer handler 无此 attr 则跳过。
  handler_cleanup <- attr(handler, "cleanup")
  if (is.function(handler_cleanup)) {
    session$onSessionEnded(function() {
      tryCatch(handler_cleanup(), error = function(e) NULL)
    })
  }

  invisible(list(
    clear = function() {
      session$sendCustomMessage(paste0(input_id, ":clear"), list())
    },
    # 注意：thread_id 默认 "default"。若用户已新建/切换线程（id 为随机生成值），
    # 必须显式传入当前 thread_id，否则消息路由到不存在的 "default" 线程被静默丢弃。
    send_tool_call = function(tool_call_id, tool_name, args = list(), thread_id = "default") {
      cbs <- make_callbacks(thread_id)
      cbs$on_tool_call(tool_call_id, tool_name, args)
    },
    send_tool_result = function(tool_call_id, result, is_error = FALSE, thread_id = "default") {
      cbs <- make_callbacks(thread_id)
      cbs$on_tool_result(tool_call_id, result, is_error)
    },
    send_sessions = function(sessions) {
      pending_sessions <<- sessions
      session$sendCustomMessage(paste0(input_id, ":sessions"), sessions)
    }
  ))
}

# NULL-coalescing helper. Intentionally kept separate from the copy in
# handlers.R: the backend layer (handlers.R + ellmer_store.R) is designed to be
# extractable into a standalone package (see .claude/plans/runtime-extraction.md),
# so the widget layer keeps its own copy to stay self-sufficient post-split.
`%||%` <- function(x, y) if (is.null(x)) y else x
