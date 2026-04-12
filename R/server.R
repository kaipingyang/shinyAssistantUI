#' Assistant UI Server Module
#'
#' Handles the server-side logic for an [assistantUIOutput()] widget: receives
#' user messages, calls a backend handler, and streams responses back to the UI.
#'
#' @param id The module ID matching the `outputId` passed to [assistantUIOutput()].
#' @param handler A function with signature
#'   `function(message, thread_id, on_chunk, on_done, on_error)` where:
#'   * `message` — character string of the user's message.
#'   * `thread_id` — character string identifying the current thread (for
#'     multi-turn conversation routing).
#'   * `on_chunk(text)` — call repeatedly to stream response tokens.
#'   * `on_done()` — call once when the response is complete.
#'   * `on_error(msg)` — call to surface an error in the UI.
#'
#'   The handler may return a promise (from `promises` or `coro`) for async
#'   streaming; errors from the promise are automatically forwarded via
#'   `on_error`.
#' @param show_thread_list Logical. If `TRUE`, a thread list sidebar is shown
#'   inside the widget for switching between conversations. Default `FALSE`
#'   (backward-compatible).
#'
#' @return A list with a `clear()` function that creates a new thread in the UI.
#' @export
assistantUIServer <- function(id, handler, show_thread_list = FALSE) {
  session  <- shiny::getDefaultReactiveDomain()
  input_id <- paste0(id, "_input")

  session$output[[id]] <- renderAssistantUI(
    config  = list(show_thread_list = show_thread_list),
    outputId = id
  )

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()

    thread_id <- msg$thread_id %||% "default"

    on_chunk <- function(text) {
      session$sendCustomMessage(paste0(input_id, ":chunk"), list(text = text))
    }
    on_done <- function() {
      session$sendCustomMessage(paste0(input_id, ":done"), list())
    }
    on_error <- function(message) {
      session$sendCustomMessage(paste0(input_id, ":error"), list(message = message))
    }

    result <- tryCatch(
      handler(
        message   = msg$text,
        thread_id = thread_id,
        on_chunk  = on_chunk,
        on_done   = on_done,
        on_error  = on_error
      ),
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
    }
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
