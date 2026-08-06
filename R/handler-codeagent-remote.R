#' Use codeagent as an OUT-OF-PROCESS backend engine (ERP-safe isolation)
#'
#' Like [make_codeagent_handler()], but runs the `codeagent` agent in a separate
#' R **worker process** pinned to a library with a compatible (new) `curl`
#' (e.g. `Rlibs/codeagent/R-4.4`). The MAIN Shiny process **never loads
#' codeagent / ellmer / curl** — so it is safe inside a session whose default
#' library has an old, incompatible `curl` (the R "one namespace version per
#' session" trap). Streaming, tool display, and permission approval are marshaled
#' over a socket; the in-app approval card + `wait_for_approval` bridge is reused
#' unchanged, just across the process boundary.
#'
#' Use this when the host session cannot load the new `curl`/`ellmer` in-process
#' (e.g. Posit Workbench / ERP with a legacy system stack). On a machine whose
#' whole environment already has a new `curl`, the lighter in-process
#' [make_codeagent_handler()] works too.
#'
#' **IMPORTANT:** The MAIN process must never `requireNamespace("codeagent")` — that would
#' load ellmer/curl into MAIN. Availability is checked with `find.package()`; the
#' worker is spawned only when a turn actually runs (or via `warmup`).
#'
#' **Phase B scope:** `register_tools = TRUE` built-in toolset + approve/deny
#' permission gating. Host-supplied domain tools (register_tools = FALSE) are not
#' yet supported across the process boundary (a live `ellmer::Chat` cannot be
#' serialized) — use [make_codeagent_handler()] in-process for that.
#'
#' @param config Named list of client construction parameters evaluated *inside*
#'   the worker: `base_url`, `model`, `api_key`, `cwd`. Missing values fall back
#'   to `OPENAI_BASE_URL` / `OPENAI_MODEL` / `OPENAI_API_KEY` (read from
#'   `renviron`). A live `Chat` object cannot be passed (not serializable).
#' @param libpath Library path the worker prepends to `.libPaths()` — the
#'   isolated codeagent lib (new curl), e.g. the shared `Rlibs/codeagent/R-4.4`.
#' @param renviron Optional path to a `.Renviron` the worker reads for
#'   credentials (a fresh R process does not auto-read a project `.Renviron`).
#' @param permission_mode Gate mode installed in the worker (default `"default"`
#'   → write/execute tools prompt via the approval card).
#' @param approval_tools Optional tool names to additionally force through
#'   approval (mapped to the gate's rules). Approve/deny only.
#'
#' @return A `coro::async` handler for [assistantUIServer()].
#' @seealso [make_codeagent_handler()] (in-process).
#' @export
make_codeagent_remote_handler <- function(config          = list(),
                                           libpath         = NULL,
                                           renviron        = NULL,
                                           permission_mode = "default",
                                           approval_tools  = character(0)) {
  cfg <- config
  cfg$permission_mode <- permission_mode
  if (length(approval_tools)) {
    cfg$rules <- lapply(as.character(approval_tools),
                        function(t) list(tool_name = t, behavior = "ask", rule_content = NULL))
  }

  workers <- list()  # thread_id -> worker handle
  get_worker <- function(thread_id) {
    ex <- workers[[thread_id]]
    if (!is.null(ex) && isTRUE(tryCatch(ex$proc$is_alive(), error = function(e) FALSE))) return(ex)
    h <- .ca_worker_start(libpath = libpath, renviron = renviron, config = cfg)
    workers[[thread_id]] <<- h
    h
  }

  coro_handler <- coro::async(function(message, thread_id, attachments,
                       on_chunk, on_done, on_error,
                       on_tool_call, on_tool_result, on_thinking,
                       on_image, on_artifact,
                       is_cancelled, wait_for_approval, register_cancel) {
    h <- get_worker(thread_id)
    if (is.function(register_cancel)) register_cancel(function() .ca_worker_cancel(h))

    atts <- attachments %||% list()
    text_sections <- .attachment_text_sections(atts)
    full_message <- message
    if (nzchar(text_sections)) full_message <- paste0(text_sections, "\n\n", message)

    on_event <- function(ev) {
      typ <- ev$ev %||% ""
      if (identical(typ, "delta")) {
        if (is.function(on_chunk)) on_chunk(ev$t %||% "")
      } else if (identical(typ, "thinking")) {
        if (is.function(on_thinking)) on_thinking(ev$t %||% "")
      } else if (identical(typ, "tool_req")) {
        if (is.function(on_tool_call))
          on_tool_call(tool_call_id = ev$id %||% "", tool_name = ev$name %||% "",
                       args = ev$args %||% list(), annotations = list(intent = ev$intent))
      } else if (identical(typ, "tool_res")) {
        .codeagent_display_to_ui(
          list(id = ev$id %||% "", name = ev$name %||% "", value = ev$value %||% "",
               is_error = isTRUE(ev$is_error), display = ev$display),
          on_image, on_artifact, on_tool_result)
      } else if (identical(typ, "ask")) {
        # Phase B approval bridge, marshaled across the process boundary.
        tuid <- ev$id %||% ""
        if (is.function(on_tool_call))
          on_tool_call(tool_call_id = tuid, tool_name = ev$name %||% "",
                       args = ev$args %||% list(), annotations = list(requiresApproval = TRUE))
        if (is.function(wait_for_approval)) {
          promises::then(
            wait_for_approval(tuid),
            function(d) .ca_worker_send(h, list(cmd = "approve", id = tuid,
                          ok = isTRUE(if (is.list(d)) d$approved else d)))
          )
        } else {
          .ca_worker_send(h, list(cmd = "approve", id = tuid, ok = FALSE))
        }
      } else if (identical(typ, "error")) {
        if (is.function(on_error)) on_error(ev$m %||% "error")
      }
      invisible()
    }

    tryCatch(
      coro::await(.ca_worker_run(h, full_message, on_event)),
      error = function(e) {
        if (!isTRUE(tryCatch(is_cancelled(), error = function(e2) FALSE)) && is.function(on_error))
          on_error(conditionMessage(e))
      }
    )
    if (is.function(on_done)) on_done()
    invisible(NULL)
  })

  # Spawn + build the worker in the background when the codeagent backend is
  # selected (assistantUIServer(prewarm=)), off the first-message critical path.
  attr(coro_handler, "warmup") <- function(thread_id) { get_worker(thread_id); invisible(NULL) }
  # Stop all worker processes (assistantUIServer calls this on session end) so
  # workers don't leak in a long-lived multi-session app.
  attr(coro_handler, "teardown") <- function() {
    for (h in workers) tryCatch(.ca_worker_stop(h), error = function(e) NULL)
    workers <<- list()
    invisible(NULL)
  }
  coro_handler
}
