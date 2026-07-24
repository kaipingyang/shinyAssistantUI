# Plan 21 / Angle A — 在用户活会话(.GlobalEnv)执行 R 并把结果回传给 Claude。
# 借鉴 simonpcouch/side（tool-run_r_code.R + tool-env.R）：rstudioapi 无 console 回传函数,
# 故用 nanonext 请求/应答 socket —— 主会话跑一个 later 轮询的"环境服务器",在 .GlobalEnv 执行
# 并捕获 值/message/warning/error;background job 侧通过 socket 发代码、同步取回结果,喂回聊天。
# `%||%` 见 handlers.R。

# ── 捕获执行（纯函数，可测）──────────────────────────────────────────────────
# 在 envir 里 eval code,收集 message/warning/error 与（可见的）返回值,组装成文本。
# 返回 list(ok, output, error)。
.addin_run_r_capture <- function(code, envir = globalenv()) {
  code_str <- paste(as.character(code), collapse = "\n")
  if (!nzchar(trimws(code_str))) return(list(ok = TRUE, output = "", error = NULL))
  messages <- character(); warnings <- character(); error_msg <- NULL
  res <- tryCatch(
    withCallingHandlers(
      withVisible(eval(parse(text = code_str), envir = envir)),
      message = function(m) {
        messages <<- c(messages, sub("\n$", "", conditionMessage(m))); invokeRestart("muffleMessage")
      },
      warning = function(w) {
        warnings <<- c(warnings, conditionMessage(w)); invokeRestart("muffleWarning")
      }
    ),
    error = function(e) { error_msg <<- conditionMessage(e); NULL }
  )
  if (!is.null(error_msg)) return(list(ok = FALSE, output = "", error = error_msg))
  out <- character()
  if (is.list(res) && isTRUE(res$visible) && !is.null(res$value)) {
    out <- c(out, utils::capture.output(print(res$value)))
  }
  if (length(messages)) out <- c(out, paste0("Message: ", messages))
  if (length(warnings)) out <- c(out, paste0("Warning: ", warnings))
  list(ok = TRUE, output = paste(out, collapse = "\n"), error = NULL)
}

# ── nanonext 环境服务器（主会话；later 轮询，console 空闲时服务）──────────────
.claude_console_state <- new.env(parent = emptyenv())

.addin_stop_r_console_server <- function() {
  if (isTRUE(.claude_console_state$active)) {
    .claude_console_state$active <- FALSE
    try(close(.claude_console_state$socket), silent = TRUE)
    .claude_console_state$socket <- NULL
  }
  invisible(TRUE)
}

# 处理一个待处理请求（若有）；无返回值风格,供 later 轮询或手动 pump 调用。
.addin_console_service_once <- function(sock, envir = globalenv(),
                                        on_echo = NULL, timeout = 150) {
  ctx <- nanonext::context(sock)
  res <- tryCatch(
    nanonext::reply(ctx, execute = function(req) {
      code <- if (is.list(req)) req$code else req
      cap <- .addin_run_r_capture(code, envir = envir)
      if (is.function(on_echo)) tryCatch(on_echo(as.character(code), cap), error = function(e) NULL)
      cap
    }, timeout = timeout),
    error = function(e) NULL
  )
  invisible(res)
}

.addin_start_r_console_server <- function(url, envir = globalenv(), echo = TRUE) {
  if (!requireNamespace("nanonext", quietly = TRUE) ||
      !requireNamespace("later", quietly = TRUE)) return(invisible(FALSE))
  .addin_stop_r_console_server()
  sock <- tryCatch(nanonext::socket("rep", listen = url), error = function(e) NULL)
  if (is.null(sock)) return(invisible(FALSE))
  .claude_console_state$socket <- sock
  .claude_console_state$active <- TRUE
  .claude_console_state$url <- url
  echo_fn <- if (isTRUE(echo)) function(code, cap) {
    cat("\n\u2500\u2500 Claude ran in console \u2500\u2500\n", code, "\n", sep = "")
    if (!is.null(cap$error)) cat("Error:", cap$error, "\n")
    else if (nzchar(cap$output)) cat(cap$output, "\n")
  } else NULL
  service <- function() {
    if (!isTRUE(.claude_console_state$active)) return(invisible(NULL))
    .addin_console_service_once(sock, envir = envir, on_echo = echo_fn)
    later::later(service, 0.1)
  }
  later::later(service, 0.1)
  invisible(TRUE)
}

# ── 客户端（background job 侧）：发代码,同步取回捕获结果 ─────────────────────
.addin_run_r_remote <- function(url, code, timeout = 15000) {
  if (!requireNamespace("nanonext", quietly = TRUE))
    return(list(ok = FALSE, output = "", error = "nanonext unavailable"))
  sock <- tryCatch(nanonext::socket("req", dial = url), error = function(e) NULL)
  if (is.null(sock)) return(list(ok = FALSE, output = "", error = "cannot reach R console server"))
  on.exit(try(close(sock), silent = TRUE), add = TRUE)
  ctx <- nanonext::context(sock)
  aio <- tryCatch(nanonext::request(ctx, data = list(code = as.character(code)), timeout = timeout),
                  error = function(e) NULL)
  if (is.null(aio)) return(list(ok = FALSE, output = "", error = "request failed"))
  nanonext::call_aio(aio)
  res <- aio$data
  if (is.null(res) || !is.list(res)) return(list(ok = FALSE, output = "", error = "console server timeout"))
  res
}


# ── Angle B (Plan 22): Claude-agentic run_r as an in-process SDK MCP tool ──────
# Claude calls run_r → (approval) → this handler runs in the background job →
# routes over nanonext to the main-session env-server (above) → the code runs
# VISIBLY in the user's live .GlobalEnv (echo) and the capture is returned to
# Claude. Reuses the Angle A env-server; needs ClaudeAgentSDK's in-process MCP
# support (create_sdk_mcp_server / sdk_mcp_tool). No new dependencies.

# autorun toggle → which allowed_tools to connect with. When on, run_r is
# auto-allowed (no approval card); when off, run_r hits the approval card.
.addin_run_r_allowed_tools <- function(autorun_on, base = NULL) {
  tool <- "mcp__r_session__run_r"
  if (!isTRUE(autorun_on)) return(base)
  if (tool %in% base) return(base)
  c(base, tool)
}

# Build the in-process "r_session" MCP server exposing run_r. Returns NULL when
# the installed ClaudeAgentSDK lacks in-process MCP support (older versions) —
# callers then simply don't register it.
.addin_run_r_server <- function(console_url, run_remote = .addin_run_r_remote,
                                timeout = 60000) {
  if (!requireNamespace("ClaudeAgentSDK", quietly = TRUE) ||
      !("create_sdk_mcp_server" %in% getNamespaceExports("ClaudeAgentSDK")))
    return(NULL)
  run_r <- ClaudeAgentSDK::sdk_mcp_tool(
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
      code <- args$code %||% ""
      cap <- tryCatch(
        run_remote(console_url, code, timeout = timeout),
        error = function(e) list(ok = FALSE, output = "", error = conditionMessage(e))
      )
      if (!isTRUE(cap$ok)) {
        return(list(
          content = list(list(type = "text",
                              text = paste0("Error: ", cap$error %||% "unknown error"))),
          isError = TRUE
        ))
      }
      out <- cap$output %||% ""
      if (!nzchar(out)) out <- "(no visible output)"
      list(content = list(list(type = "text", text = out)), isError = FALSE)
    }
  )
  ClaudeAgentSDK::create_sdk_mcp_server("r_session", tools = list(run_r))
}
