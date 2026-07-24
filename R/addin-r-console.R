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
