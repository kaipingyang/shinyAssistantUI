#' The assistantUIServer handler contract
#'
#' The `handler` passed to [assistantUIServer()] is the sole integration point
#' between a chat backend and the UI. This page freezes that contract so the
#' backend layer (`make_ellmer_handler()`, `make_claude_handler()`, ...) can be
#' developed — and eventually extracted into a standalone, UI-agnostic package —
#' independently of the Shiny widget.
#'
#' @section Signature:
#' The handler is a function (optionally `coro::async`) that declares any subset
#' of the following parameters, plus `...`. `assistantUIServer()` injects only
#' the parameters the handler actually declares (matched by name via
#' `names(formals(handler))`), so unused callbacks may be omitted safely.
#'
#' ```r
#' handler <- function(message, thread_id,
#'                     on_chunk, on_done, on_error,
#'                     on_tool_call, on_tool_call_start, on_tool_call_delta,
#'                     on_tool_result, on_thinking,
#'                     on_source, on_image, on_artifact,
#'                     attachments, is_reload, is_cancelled,
#'                     wait_for_approval, register_cancel, ...) { ... }
#' ```
#'
#' @section Inputs:
#' * `message` — character. The user's text (slash commands already expanded).
#' * `thread_id` — character. The UI thread this run belongs to.
#' * `attachments` — list of uploaded attachments (image/text/file).
#' * `is_reload` — logical. `TRUE` when regenerating a previous reply.
#' * `is_cancelled` — `function()` returning `TRUE` if the user hit Stop.
#' * `wait_for_approval` — `function(tool_call_id)` returning a promise that
#'   resolves with the user's approval decision (for `requiresApproval` tools).
#' * `register_cancel` — `function(fn)` to register a cancel/interrupt callback
#'   invoked when the user hits Stop.
#'
#' @section Output callbacks:
#' * `on_chunk(text)` — stream a response token.
#' * `on_done(suggestions = list())` — finish; optional followup suggestions.
#' * `on_error(message)` — surface an error.
#' * `on_thinking(text)` — stream reasoning/thinking content.
#' * `on_tool_call(tool_call_id, tool_name, args, annotations)` — a completed
#'   tool call (whole-package path).
#' * `on_tool_call_start(tool_call_id, tool_name, annotations)` /
#'   `on_tool_call_delta(tool_call_id, delta)` — streaming tool-args path.
#' * `on_tool_result(tool_call_id, result, is_error)` — a tool's result.
#' * `on_source(url, title, id)` — attach a citation/source footnote.
#' * `on_image(image)` — render an inline image (URL or data URI).
#' * `on_artifact(id, title, content, type, lang)` — open/update a side-panel
#'   artifact (`type`: markdown/code/html/text).
#'
#' @section Runtime expectation (for non-Shiny consumers):
#' An `coro::async` handler suspends on `await`/promises and therefore requires
#' an event loop that services `later` callbacks to make progress. Shiny's
#' `ExtendedTask` (used by [assistantUIServer()]) provides this automatically. A
#' non-Shiny consumer of the backend layer must pump the loop itself (e.g.
#' `later::run_now()` in a loop) for streaming and `wait_for_approval` to work.
#'
#' @seealso [assistantUIServer()], [make_ellmer_handler()], [make_claude_handler()]
#' @name assistant-handler-contract
#' @keywords internal
NULL
