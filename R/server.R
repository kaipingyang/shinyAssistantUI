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
#'   * `on_tool_call(tool_call_id, tool_name, args)` — show a tool call card
#'     (args should be a named list).
#'   * `on_tool_result(tool_call_id, result, is_error = FALSE)` — update the
#'     tool card with the result.
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
#'     For [ClaudeAgentSDK][https://github.com/kaipingyang/ClaudeAgentSDK],
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
#'   with `name` (e.g. `"summarize"`), `description`, and `prompt` (the message
#'   sent immediately when the command is selected).
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
#'
#' @return A list with a `clear()` function that creates a new thread in the UI.
#' @export
assistantUIServer <- function(id, handler,
                              show_thread_list  = FALSE,
                              suggestions       = list(),
                              commands          = list(),
                              tools             = list(),
                              code_theme        = "one-light",
                              strings           = NULL,
                              assistant_avatar  = list(fallback = "AI")) {
  force(show_thread_list); force(suggestions); force(commands)
  force(tools); force(code_theme); force(strings); force(assistant_avatar)
  session  <- shiny::getDefaultReactiveDomain()
  input_id <- paste0(id, "_input")

  config <- list(
    show_thread_list = show_thread_list,
    suggestions      = suggestions,
    commands         = commands,
    tools            = tools,
    code_theme       = code_theme
  )
  if (!is.null(strings))          config$strings          <- strings
  if (!is.null(assistant_avatar)) config$assistant_avatar <- assistant_avatar

  session$output[[id]] <- renderAssistantUI(
    config   = config,
    outputId = id
  )

  # 每线程 cancel 标志（mutable environment，cancel 信号到达时设为 TRUE）
  cancel_flags <- new.env(parent = emptyenv())

  # ── 静态回调（整个 session 不变）────────────────────────────────────────────
  on_chunk <- function(text) {
    session$sendCustomMessage(paste0(input_id, ":chunk"), list(text = text))
  }
  on_done <- function() {
    session$sendCustomMessage(paste0(input_id, ":done"), list())
  }
  on_error_fn <- function(msg) {
    session$sendCustomMessage(paste0(input_id, ":error"), list(message = msg))
  }
  on_tool_call <- function(tool_call_id, tool_name, args = list(),
                           annotations = list()) {
    session$sendCustomMessage(
      paste0(input_id, ":tool-call"),
      list(
        toolCallId  = tool_call_id,
        toolName    = tool_name,
        args        = args,
        argsText    = as.character(jsonlite::toJSON(args, auto_unbox = TRUE, pretty = FALSE)),
        annotations = annotations
      )
    )
  }
  on_tool_result <- function(tool_call_id, result, is_error = FALSE) {
    session$sendCustomMessage(
      paste0(input_id, ":tool-result"),
      list(toolCallId = tool_call_id, result = result, isError = is_error)
    )
  }
  on_thinking <- function(text) {
    session$sendCustomMessage(paste0(input_id, ":thinking"), list(text = text))
  }

  # ── tool 审批 ────────────────────────────────────────────────────────────────
  # wait_for_approval 用 observeEvent 驱动。
  # 关键：handler 必须通过 ExtendedTask 启动（见下方 stream_task），
  # 只有 ExtendedTask 才允许 Shiny reactive flush 在 coro::await 挂起期间运行；
  # 直接从 observeEvent 里启动 handler 则不会触发 reactive flush，导致审批 observer 死锁。
  approval_resolvers <- new.env(parent = emptyenv())

  shiny::observeEvent(session$input[[paste0(input_id, "_tool_approval")]], {
    msg <- session$input[[paste0(input_id, "_tool_approval")]]
    if (is.null(msg)) return()
    tid <- msg$toolCallId
    resolver <- get0(tid, envir = approval_resolvers)
    if (!is.null(resolver)) {
      rm(list = tid, envir = approval_resolvers)
      resolver(isTRUE(msg$approved))
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  wait_for_approval <- function(tool_call_id) {
    promises::promise(function(resolve, reject) {
      assign(tool_call_id, resolve, envir = approval_resolvers)
    })
  }

  # 独立 observer 监听 cancel 信号
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    if (is.null(msg)) return()
    tid <- msg$threadId %||% "default"
    assign(tid, TRUE, envir = cancel_flags)
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # ── ExtendedTask：以 Shiny-aware 异步任务运行 handler ────────────────────────
  # ExtendedTask 让 Shiny 知道有长时任务在运行，允许 reactive flush 在 await 期间发生，
  # 从而 _tool_approval / _cancel 等 observer 可以正常触发。
  stream_task <- shiny::ExtendedTask$new(
    function(msg_text, thread_id, is_reload, attachments) {
      is_cancelled <- function() isTRUE(get0(thread_id, envir = cancel_flags))

      all_args <- list(
        message           = msg_text,
        thread_id         = thread_id,
        on_chunk          = on_chunk,
        on_done           = on_done,
        on_error          = on_error_fn,
        on_tool_call      = on_tool_call,
        on_tool_result    = on_tool_result,
        on_thinking       = on_thinking,
        attachments       = attachments,
        is_reload         = is_reload,
        is_cancelled      = is_cancelled,
        wait_for_approval = wait_for_approval
      )
      handler_params <- names(formals(handler))
      call_args <- if ("..." %in% handler_params) all_args
                   else all_args[names(all_args) %in% handler_params]

      result <- tryCatch(
        do.call(handler, call_args),
        error = function(e) { on_error_fn(conditionMessage(e)); NULL }
      )
      # 返回 promise（如有）让 ExtendedTask 追踪其生命周期
      if (inherits(result, "promise")) {
        promises::catch(result, function(e) { on_error_fn(conditionMessage(e)); NULL })
      }
    }
  )

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()

    thread_id <- msg$threadId %||% "default"
    is_reload <- identical(msg$type, "reload")

    # 新 run 开始前重置 cancel 标志
    assign(thread_id, FALSE, envir = cancel_flags)

    stream_task$invoke(
      msg$text,
      thread_id,
      is_reload,
      msg$attachments %||% list()
    )
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  invisible(list(
    clear = function() {
      session$sendCustomMessage(paste0(input_id, ":clear"), list())
    },
    send_tool_call = function(tool_call_id, tool_name, args = list()) {
      on_tool_call(tool_call_id, tool_name, args)
    },
    send_tool_result = function(tool_call_id, result, is_error = FALSE) {
      on_tool_result(tool_call_id, result, is_error)
    }
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
