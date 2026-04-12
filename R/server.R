#' Assistant UI Server Module
#'
#' Handles the server-side logic for an [assistantUIOutput()] widget: receives
#' user messages, calls a backend handler, and streams responses back to the UI.
#'
#' @param id The module ID matching the `outputId` passed to [assistantUIOutput()].
#' @param handler A function with signature
#'   `function(message, on_chunk, on_done, on_error)` where:
#'   * `message` — character string of the user's message.
#'   * `on_chunk(text)` — call repeatedly to stream response tokens.
#'   * `on_done()` — call once when the response is complete.
#'   * `on_error(msg)` — call to surface an error in the UI.
#'
#' @return A Shiny module server (invisibly).
#' @export
assistantUIServer <- function(id, handler) {
  session   <- shiny::getDefaultReactiveDomain()
  input_id  <- paste0(id, "_input")

  session$output[[id]] <- renderAssistantUI(config = list(), outputId = id)

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg) || !nzchar(trimws(msg$text %||% ""))) return()

    on_chunk <- function(text) {
      session$sendCustomMessage(paste0(input_id, ":chunk"), list(text = text))
    }
    on_done <- function() {
      session$sendCustomMessage(paste0(input_id, ":done"), list())
    }
    on_error <- function(message) {
      session$sendCustomMessage(paste0(input_id, ":error"), list(message = message))
    }

    tryCatch(
      handler(
        message  = msg$text,
        on_chunk = on_chunk,
        on_done  = on_done,
        on_error = on_error
      ),
      error = function(e) on_error(conditionMessage(e))
    )
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  invisible(list(
    clear = function() {
      session$sendCustomMessage(paste0(input_id, ":clear"), list())
    }
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x
