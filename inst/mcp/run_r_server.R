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

run_r <- sdk_mcp_tool(
  name = "run_r",
  description = paste(
    "Execute R code in the user's LIVE R session (.GlobalEnv).",
    "Use this to inspect or use their real data, objects and loaded packages.",
    "Output and errors are returned as text (no images)."
  ),
  input_schema = list(code = list(
    type = "string",
    description = "R code to run in the user's live R session (.GlobalEnv)."
  )),
  handler = function(args) {
    cap <- .run_remote(console_url, args$code %||% "")
    if (!isTRUE(cap$ok)) {
      return(list(
        content = list(list(type = "text",
                            text = paste0("Error: ", cap$error %||% "unknown error"))),
        isError = TRUE
      ))
    }
    out <- cap$output %||% ""
    if (!nzchar(out)) out <- "(no visible output)"
    list(content = list(list(type = "text", text = out)))
  }
)

ClaudeAgentSDK::mcp_serve_stdio(
  ClaudeAgentSDK::create_sdk_mcp_server("r_session", tools = list(run_r))
)
