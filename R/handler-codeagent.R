#' Use codeagent as the backend engine
#'
#' Adapter that lets [assistantUIServer()] drive a
#' \href{https://github.com/kaipingyang/codeagent}{codeagent} agent instead of a
#' bare `ellmer::Chat` — gaining codeagent's harness (multi-turn self-healing,
#' central permission gate, compaction, skills/hooks, lossless sessions). It is a
#' pure addition: it does not modify or replace [make_ellmer_handler()] /
#' `make_claude_handler()`; hosts that never call it are unaffected.
#'
#' **Phase B (this release):** streaming + typed tool display forwarding **plus
#' permission approval** — sensitive tools (write/execute) are gated by
#' codeagent's central permission gate, bridged to the in-app approval card. No
#' concurrent sub-agents yet (background agents are a follow-up phase). Requires
#' the `codeagent` package (Suggests).
#'
#' @param permission_mode codeagent permission mode installed on the gate:
#'   `"default"` (write/execute tools prompt for approval; reads auto-allow),
#'   `"acceptEdits"`, `"plan"`, or `"bypassPermissions"`/`"bypass"` (auto-run,
#'   no prompts — trusted environments only). The handler owns this policy (it
#'   drives the UI approval card), overriding any mode set on the client.
#'
#' @param client_factory `function()` returning a codeagent client, e.g.
#'   `function() codeagent::codeagent_client(chat = my_chat, register_tools = FALSE)`.
#'   The host constructs the client so it controls the model, permission mode,
#'   and which domain tools to register. Called once per thread (cached).
#' @param approval_tools Optional character vector of tool names to *additionally*
#'   force through approval (mapped to the gate's `rules$ask`), on top of what
#'   `permission_mode` already prompts for. Note: only approve/deny is supported
#'   for codeagent tools — the gate cannot rewrite tool input, so any edited
#'   arguments (`decision$updatedInput`) are ignored (that is a Claude-only
#'   feature via `client$approve_tool(updated_input=)`).
#' @param store Optional persistence adapter with a `save(thread_id, client, ...)`
#'   method (Phase C uses codeagent's lossless session instead).
#' @param stream_fn Advanced/testing: the streaming function to drive. Defaults
#'   to `codeagent::codeagent_stream_async`. Injectable so the adapter can be
#'   unit-tested without a live model.
#' @param gate_fn Advanced/testing: the permission-gate installer. Defaults to
#'   `codeagent::install_permission_gate`. Injectable so the approval bridge can
#'   be unit-tested (and, later, replaced by an out-of-process transport)
#'   without a live gate.
#'
#' @return A `coro::async` handler suitable for [assistantUIServer()]'s `handler`.
#' @seealso [make_ellmer_handler()] for the lighter bare-ellmer backend.
#' @export
make_codeagent_handler <- function(client_factory,
                                    approval_tools  = character(0),
                                    permission_mode = "default",
                                    store           = NULL,
                                    stream_fn       = NULL,
                                    gate_fn         = NULL) {
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
  gate_fn <- gate_fn %||% function(chat, permission_mode, ask_fn, rules = list()) {
    if (!requireNamespace("codeagent", quietly = TRUE)) {
      stop("make_codeagent_handler() requires the 'codeagent' package. ",
           "Install it, or pass a custom `gate_fn`.", call. = FALSE)
    }
    codeagent::install_permission_gate(chat, permission_mode = permission_mode,
                                       ask_fn = ask_fn, rules = rules)
  }
  # Extra tools to force through approval, on top of `permission_mode`'s policy.
  # codeagent's gate iterates `rules` as PermissionRule-shaped objects
  # (list(tool_name=, behavior=, rule_content=)) — first match wins, evaluated
  # before the default read-only auto-allow — so this can force even a read tool
  # to prompt. (A bare list(ask=...) is the WRONG shape and errors in the gate.)
  gate_rules <- if (length(approval_tools))
    lapply(as.character(approval_tools),
           function(t) list(tool_name = t, behavior = "ask", rule_content = NULL))
    else list()

  clients <- list()  # thread_id -> list(client, current)
  get_client <- function(thread_id) {
    if (!is.null(clients[[thread_id]])) return(clients[[thread_id]])
    cl <- client_factory()

    # Per-thread mutable env holding the CURRENT run's UI callbacks so the gate's
    # ask_fn (installed once, below) can reach them. Mirrors make_ellmer_handler.
    current <- new.env(parent = emptyenv())
    current$on_tool_call      <- NULL
    current$on_tool_result    <- NULL
    current$wait_for_approval <- NULL

    # Bridge codeagent's central permission gate -> assistant-ui approval card.
    # A plain function returning a promise<logical> (the gate awaits it on the
    # Shiny path). NO coro here (avoids coro's statement-form trap). It only
    # closes over `current`, so an out-of-process worker can later marshal the
    # same {ask id name input} -> logical contract across the process boundary.
    ask_fn <- function(name, input, id = NULL) {
      tuid <- id %||% ""
      if (is.function(current$on_tool_call)) {
        tryCatch(current$on_tool_call(
          tool_call_id = tuid, tool_name = name, args = input,
          annotations  = list(requiresApproval = TRUE)
        ), error = function(e) NULL)
      }
      if (is.function(current$wait_for_approval)) {
        promises::then(
          current$wait_for_approval(tuid),
          function(d) isTRUE(if (is.list(d)) d$approved else d)
        )
      } else {
        FALSE  # no approval channel -> deny (safe default under "default" mode)
      }
    }

    chat_obj <- tryCatch(cl$chat, error = function(e) NULL)
    if (!is.null(chat_obj)) {
      tryCatch(
        gate_fn(chat_obj, permission_mode = permission_mode,
                ask_fn = ask_fn, rules = gate_rules),
        error = function(e) NULL
      )
    }

    obj <- list(client = cl, current = current)
    clients[[thread_id]] <<- obj
    obj
  }

  coro_handler <- coro::async(function(message, thread_id, attachments,
                       on_chunk, on_done, on_error,
                       on_tool_call, on_tool_result, on_thinking,
                       on_image, on_artifact,
                       is_cancelled, wait_for_approval, register_cancel) {
    obj     <- get_client(thread_id)
    client  <- obj$client
    current <- obj$current
    # Wire this run's UI callbacks so the gate's ask_fn (installed once per
    # thread) reaches the live approval channel. Serial per thread -> no race.
    current$on_tool_call      <- on_tool_call
    current$on_tool_result    <- on_tool_result
    current$wait_for_approval <- wait_for_approval

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

    # Detach this run's callbacks (mirrors make_ellmer_handler); the gate stays
    # installed for the next run, which re-wires `current`.
    current$on_tool_call      <- NULL
    current$on_tool_result    <- NULL
    current$wait_for_approval <- NULL

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
