#' Assistant UI Server Module
#'
#' Handles the server-side logic for an [assistantUIOutput()] widget: receives
#' user messages, calls a backend handler, and streams responses back to the UI.
#'
#' @param id The module ID matching the `outputId` passed to [assistantUIOutput()].
#' @param handler A function with signature
#'   `function(message, thread_id, on_chunk, on_done, on_error,
#'              on_tool_call, on_tool_result)` where:
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
#'
#'   `on_tool_call` and `on_tool_result` are optional: handlers that omit
#'   them continue to work unchanged.
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
#'
#' @return A list with a `clear()` function that creates a new thread in the UI.
#' @export
assistantUIServer <- function(id, handler,
                              show_thread_list = FALSE,
                              suggestions      = list(),
                              commands         = list(),
                              tools            = list()) {
  session  <- shiny::getDefaultReactiveDomain()
  input_id <- paste0(id, "_input")

  session$output[[id]] <- renderAssistantUI(
    config = list(
      show_thread_list = show_thread_list,
      suggestions      = suggestions,
      commands         = commands,
      tools            = tools
    ),
    outputId = id
  )

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()

    thread_id <- msg$threadId %||% "default"

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
      on_tool_result = on_tool_result  # function(id, result, is_error)
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
