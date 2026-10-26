# Curl-free stdio MCP server exposing `run_r` (Plan 22 / Angle B).
#
# Launched by the claude CLI as an EXTERNAL stdio MCP server (type = "stdio").
# We use stdio — NOT an in-process (type="sdk") server — because the CLI stalls
# ~50s on the first message when an in-process server is registered and the
# client connection idles first (see Plan 22). A stdio server is initialized at
# CLI startup and does not hit that stall.
#
# Depends only on ClaudeAgentSDK (mcp_serve_stdio / dispatch) + nanonext — NO
# ellmer / curl. The run_r handler routes code over nanonext to the main R
# session's env-server (Angle A) at $CLAUDE_ADDIN_CONSOLE_URL, where it runs in
# the user's live .GlobalEnv (visibly, echoed to the console) and the captured
# output is returned to Claude.
suppressPackageStartupMessages(library(ClaudeAgentSDK))
`%||%` <- function(x, y) if (is.null(x)) y else x

console_url <- Sys.getenv("CLAUDE_ADDIN_CONSOLE_URL", "")

# Minimal nanonext request to the main-session env-server (mirrors
# shinyAssistantUI:::.addin_run_r_remote, inlined to keep this subprocess lean).
.run_remote <- function(url, code, timeout = 60000) {
  if (!nzchar(url) || !requireNamespace("nanonext", quietly = TRUE))
    return(list(ok = FALSE, output = "", error = "R console server unavailable"))
  sock <- tryCatch(nanonext::socket("req", dial = url), error = function(e) NULL)
  if (is.null(sock)) return(list(ok = FALSE, output = "", error = "cannot reach R console server"))
  on.exit(try(close(sock), silent = TRUE), add = TRUE)
  ctx <- nanonext::context(sock)
  aio <- tryCatch(nanonext::request(ctx, data = list(code = as.character(code)), timeout = timeout),
                  error = function(e) NULL)
  if (is.null(aio)) return(list(ok = FALSE, output = "", error = "request failed"))
  nanonext::call_aio(aio)
  res <- aio$data
  if (!is.list(res)) return(list(ok = FALSE, output = "", error = "console server timeout"))
  res
}

# Build the MCP tool result. Output printed before an error is returned together
# with the error (Plan 163), so Claude sees every intermediate result.
.format_run_r_result <- function(cap) {
  out <- as.character(cap$output %||% "")
  if (!isTRUE(cap$ok)) {
    err <- paste0("Error: ", cap$error %||% "unknown error")
    text <- if (nzchar(out)) paste0(out, "\n", err) else err
    return(list(content = list(list(type = "text", text = text)), isError = TRUE))
  }
  if (!nzchar(out)) out <- "(no visible output)"
  list(content = list(list(type = "text", text = out)))
}

# Plan 163: when the addin provides a review endpoint, the user must approve the
# exact text before it is returned. Any failure declines; the output never leaks.
review_url <- Sys.getenv("CLAUDE_ADDIN_REVIEW_URL", "")
review_thread <- Sys.getenv("CLAUDE_ADDIN_THREAD_ID", "")
review_timeout <- suppressWarnings(as.numeric(Sys.getenv("CLAUDE_ADDIN_REVIEW_TIMEOUT_MS", "630000")))
if (!is.finite(review_timeout) || review_timeout <= 0) review_timeout <- 630000

.review_remote <- function(url, payload, timeout) {
  if (!requireNamespace("nanonext", quietly = TRUE)) return(NULL)
  sock <- tryCatch(nanonext::socket("req", dial = url), error = function(e) NULL)
  if (is.null(sock)) return(NULL)
  on.exit(try(close(sock), silent = TRUE), add = TRUE)
  aio <- tryCatch(nanonext::request(nanonext::context(sock), data = payload, timeout = timeout),
                  error = function(e) NULL)
  if (is.null(aio)) return(NULL)
  nanonext::call_aio(aio)
  if (is.list(aio$data)) aio$data else NULL
}

.declined_result <- function(reason) {
  why <- switch(reason %||% "",
    user = "the user declined",
    timeout = "the review timed out",
    stopped = "the run was stopped",
    no_reviewer = "no reviewer was connected",
    "the review could not be completed"
  )
  list(content = list(list(type = "text", text = paste0(
    "The user did not approve sharing this R output (", why, "). ",
    "The code already ran in the user's R session; do not re-run it just to obtain ",
    "the output. Ask the user if you need specific information from it."
  ))), isError = TRUE)
}

.review_result <- function(code, result) {
  text <- result$content[[1]]$text
  request_id <- paste0(format(as.numeric(Sys.time()) * 1e6, scientific = FALSE), "-",
                       paste(sample(c(letters, 0:9), 16, replace = TRUE), collapse = ""))
  reply <- tryCatch(.review_remote(review_url, list(
    type = "run_r_output_review", version = 1L, request_id = request_id,
    thread_id = review_thread, code = as.character(code), text = text,
    is_error = isTRUE(result$isError)
  ), review_timeout), error = function(e) NULL)
  # A decision for another request must never release this output.
  if (!is.list(reply) || !identical(reply$request_id, request_id)) {
    return(.declined_result(NULL))
  }
  decision <- reply$decision
  if (identical(decision, "approve")) return(result)
  edited <- if (is.list(reply)) reply$text else NULL
  if (identical(decision, "edit") && is.character(edited) && length(edited) == 1L &&
      !is.na(edited)) {
    result$content[[1]]$text <- paste0(
      "[The user edited this output before sharing it.]\n", edited
    )
    return(result)
  }
  .declined_result(if (is.list(reply)) reply$reason else NULL)
}

.run_r_result <- function(code) {
  result <- .format_run_r_result(.run_remote(console_url, code))
  if (nzchar(review_url)) result <- .review_result(code, result)
  result
}

run_r <- sdk_mcp_tool(
  name = "run_r",
  description = paste(
    "Execute R code in the user's LIVE R session (.GlobalEnv).",
    "Use this to inspect or use their real data, objects and loaded packages.",
    "Output and errors are returned as text (no images): every printed or visible",
    "top-level result in order, plus output produced before an error."
  ),
  input_schema = list(code = list(
    type = "string",
    description = "R code to run in the user's live R session (.GlobalEnv)."
  )),
  handler = function(args) .run_r_result(args$code %||% "")
)

# Tests source this script to exercise .run_r_result without starting stdio.
if (!identical(Sys.getenv("SHINY_ASSISTANT_UI_RUN_R_NO_SERVE"), "1")) {
  ClaudeAgentSDK::mcp_serve_stdio(
    ClaudeAgentSDK::create_sdk_mcp_server("r_session", tools = list(run_r))
  )
}
