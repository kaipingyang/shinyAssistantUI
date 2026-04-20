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

  # 独立 observer 监听 cancel 信号（与主消息 observer 分离，避免 Shiny promise 重入问题）
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    if (is.null(msg)) return()
    tid <- msg$threadId %||% "default"
    assign(tid, TRUE, envir = cancel_flags)
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()

    thread_id  <- msg$threadId %||% "default"
    is_reload  <- identical(msg$type, "reload")

    # 新 run 开始前重置 cancel 标志
    assign(thread_id, FALSE, envir = cancel_flags)
    # is_cancelled() 供 handler 在 chunk 循环中轮询
    is_cancelled <- function() isTRUE(get0(thread_id, envir = cancel_flags))

    on_chunk <- function(text) {
      session$sendCustomMessage(paste0(input_id, ":chunk"), list(text = text))
    }
    on_done <- function() {
      session$sendCustomMessage(paste0(input_id, ":done"), list())
    }
    on_error <- function(message) {
      session$sendCustomMessage(paste0(input_id, ":error"), list(message = message))
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

    # 向后兼容：只传 handler 实际声明的参数
    all_args <- list(
      message        = msg$text,
      thread_id      = thread_id,
      on_chunk       = on_chunk,
      on_done        = on_done,
      on_error       = on_error,
      on_tool_call   = on_tool_call,   # function(id, name, args, annotations)
      on_tool_result = on_tool_result, # function(id, result, is_error)
      attachments    = msg$attachments %||% list(), # list of attachment objects
      is_reload      = is_reload,      # TRUE 时为重新生成请求
      is_cancelled   = is_cancelled    # function() 返回 TRUE 表示用户已取消
    )
    handler_params <- names(formals(handler))
    call_args <- if ("..." %in% handler_params) all_args
                 else all_args[names(all_args) %in% handler_params]

    result <- tryCatch(
      do.call(handler, call_args),
      error = function(e) on_error(conditionMessage(e))
    )

    # 支持异步 handler（返回 promise）
    if (inherits(result, "promise")) {
      promises::catch(result, function(e) on_error(conditionMessage(e)))
    }
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
