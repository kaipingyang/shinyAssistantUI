#' Use codeagent as the backend engine
#'
#' Adapter that lets [assistantUIServer()] drive a
#' \href{https://github.com/kaipingyang/codeagent}{codeagent} agent instead of a
#' bare `ellmer::Chat` — gaining codeagent's harness (multi-turn self-healing,
#' central permission gate, compaction, skills/hooks, lossless sessions). It is a
#' pure addition: it does not modify or replace [make_ellmer_handler()] /
#' `make_claude_handler()`; hosts that never call it are unaffected.
#'
#' **Phase A (this release):** streaming + typed tool display forwarding, no
#' permission gating and no concurrent sub-agents (permission approval and
#' background agents are follow-up phases). Requires the `codeagent` package
#' (Suggests).
#'
#' @param client_factory `function()` returning a codeagent client, e.g.
#'   `function() codeagent::codeagent_client(chat = my_chat, register_tools = FALSE)`.
#'   The host constructs the client so it controls the model, permission mode,
#'   and which domain tools to register. Called once per thread (cached).
#' @param approval_tools Character vector of tool names that should prompt for
#'   approval. Reserved for Phase B (permission gating); currently unused.
#' @param store Optional persistence adapter with a `save(thread_id, client, ...)`
#'   method (Phase C uses codeagent's lossless session instead).
#' @param stream_fn Advanced/testing: the streaming function to drive. Defaults
#'   to `codeagent::codeagent_stream_async`. Injectable so the adapter can be
#'   unit-tested without a live model.
#'
#' @return A `coro::async` handler suitable for [assistantUIServer()]'s `handler`.
#' @seealso [make_ellmer_handler()] for the lighter bare-ellmer backend.
#' @export
make_codeagent_handler <- function(client_factory,
                                    approval_tools = character(0),
                                    store          = NULL,
                                    stream_fn      = NULL) {
  if (!is.function(client_factory)) {
    stop("make_codeagent_handler(): `client_factory` must be a function returning a codeagent client.",
         call. = FALSE)
  }
  stream_fn <- stream_fn %||% function(...) {
    if (!requireNamespace("codeagent", quietly = TRUE)) {
      stop("make_codeagent_handler() requires the 'codeagent' package. ",
           "Install it, or pass a custom `stream_fn`.", call. = FALSE)
    }
    codeagent::codeagent_stream_async(...)
  }

  clients <- list()  # thread_id -> codeagent client (cached per thread)
  get_client <- function(thread_id) {
    if (!is.null(clients[[thread_id]])) return(clients[[thread_id]])
    cl <- client_factory()
    clients[[thread_id]] <<- cl
    cl
  }

  coro_handler <- coro::async(function(message, thread_id, attachments,
                       on_chunk, on_done, on_error,
                       on_tool_call, on_tool_result, on_thinking,
                       on_image, on_artifact,
                       is_cancelled, wait_for_approval, register_cancel) {
    client <- get_client(thread_id)

    # Attachments: codeagent's input is text; fold text/file sections into the
    # message (image attachments are deferred to a later phase).
    atts <- attachments %||% list()
    text_sections <- .attachment_text_sections(atts)
    full_message <- message
    if (nzchar(text_sections)) full_message <- paste0(text_sections, "\n\n", message)

    ctrl <- tryCatch(ellmer::stream_controller(), error = function(e) NULL)
    if (!is.null(ctrl) && is.function(register_cancel)) {
      register_cancel(function() tryCatch(ctrl$cancel("User interrupted"), error = function(e) NULL))
    }

    # codeagent on_tool_request(list(id, name, arguments, intent)) -> UI tool card.
    # Phase A: preview only (no permission gate).
    handle_tool_request <- function(req) {
      if (is.function(on_tool_call)) {
        tryCatch(on_tool_call(
          tool_call_id = req$id %||% "",
          tool_name    = req$name %||% "",
          args         = req$arguments %||% list(),
          annotations  = list(intent = req$intent)
        ), error = function(e) NULL)
      }
    }
    # codeagent on_tool_result(list(id, name, display, value, is_error)) -> split
    # the typed display to on_image / on_artifact / on_tool_result.
    handle_tool_result <- function(res) {
      .codeagent_display_to_ui(res, on_image, on_artifact, on_tool_result)
    }

    result <- tryCatch(
      coro::await(stream_fn(
        client, full_message,
        on_delta        = if (is.function(on_chunk)) on_chunk else NULL,
        on_thinking     = if (is.function(on_thinking)) on_thinking else NULL,
        on_tool_request = handle_tool_request,
        on_tool_result  = handle_tool_result,
        on_error        = function(msg, recovered = FALSE) if (is.function(on_error)) on_error(msg),
        controller      = ctrl,
        session_id      = thread_id
      )),
      error = function(e) {
        if (!isTRUE(tryCatch(is_cancelled(), error = function(e2) FALSE)) && is.function(on_error)) {
          on_error(conditionMessage(e))
        }
        NULL
      }
    )

    if (!is.null(store) && !isTRUE(tryCatch(is_cancelled(), error = function(e) FALSE))) {
      tryCatch(store$save(thread_id, client,
                          title = substr(message, 1, 40), first_msg = substr(message, 1, 200)),
               error = function(e) NULL)
    }

    if (is.function(on_done)) on_done()
    invisible(result)
  })

  # Cold-start optimization: building a codeagent client (system prompt + tool
  # registration) takes a few seconds. Expose a `warmup` attribute so
  # assistantUIServer(prewarm=/allow_warmup=) pre-builds it in the background
  # (via later, off the first-message critical path) with a warming indicator,
  # so the first message isn't blocked by construction.
  attr(coro_handler, "warmup") <- function(thread_id) {
    get_client(thread_id)
    invisible(NULL)
  }
  coro_handler
}

# Split codeagent's typed tool `display` (toolcard: kind ∈ text/table/image/code/diff/error)
# to assistant-ui's rich callbacks. Falls back to a plain tool result. Never throws.
.codeagent_display_to_ui <- function(res, on_image, on_artifact, on_tool_result) {
  id       <- res$id %||% ""
  value    <- tryCatch(as.character(res$value %||% ""), error = function(e) "")
  is_error <- isTRUE(res$is_error)
  display  <- tryCatch(res$display, error = function(e) NULL)
  tc       <- tryCatch(display$toolcard, error = function(e) NULL)
  kind     <- tryCatch(tc$kind, error = function(e) NULL) %||% "text"
  payload  <- tryCatch(tc$payload, error = function(e) list()) %||% list()
  title    <- tryCatch(as.character(tc$title %||% res$name %||% kind), error = function(e) kind)

  if (identical(kind, "image") && is.function(on_image)) {
    imgs <- payload$images %||% list()
    if (length(imgs)) {
      im  <- imgs[[1]]
      mime <- im$mime %||% im$type %||% "image/png"
      if (!grepl("/", mime)) mime <- paste0("image/", mime)  # "png" -> "image/png"
      uri <- if (!is.null(im$b64)) paste0("data:", mime, ";base64,", im$b64) else (im$src %||% value)
      tryCatch(on_image(uri), error = function(e) NULL)
      return(invisible())
    }
  }

  if (kind %in% c("code", "diff") && is.function(on_artifact)) {
    content <- tryCatch(as.character(payload$text %||% value), error = function(e) value)
    lang    <- if (identical(kind, "diff")) "diff" else (payload$lang %||% "r")
    tryCatch(on_artifact(id = id, title = title, content = content, type = "code", lang = lang),
             error = function(e) NULL)
    return(invisible())
  }

  if (identical(kind, "table") && is.function(on_artifact)) {
    md <- tryCatch(as.character(display$markdown %||% value), error = function(e) value)
    tryCatch(on_artifact(id = id, title = title, content = md, type = "markdown"),
             error = function(e) NULL)
    return(invisible())
  }

  if (is.function(on_tool_result)) {
    tryCatch(on_tool_result(tool_call_id = id, result = value, is_error = is_error),
             error = function(e) NULL)
  }
  invisible()
}
