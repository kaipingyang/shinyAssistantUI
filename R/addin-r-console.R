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
  # box 用引用型环境接住 withVisible 结果:capture.output 在 parent.frame() 里求值,
  # 用 `<<-`/`<-` 都无法把值可靠地写回本函数的局部变量(作用域问题),改用环境按引用回写。
  box <- new.env(parent = emptyenv())
  # 关键:用 capture.output 包住 eval,捕获 cat()/print() 等写到 stdout 的输出
  # (之前只取 withVisible 的可见返回值 → cat 直接进了真实 console,Claude 收到空 → 显示
  #  "(no visible output)" 并重试,看起来像"慢一拍/不执行")。
  printed <- tryCatch(
    utils::capture.output(
      box$vis <- withCallingHandlers(
        withVisible(eval(parse(text = code_str), envir = envir)),
        message = function(m) {
          messages <<- c(messages, sub("\n$", "", conditionMessage(m))); invokeRestart("muffleMessage")
        },
        warning = function(w) {
          warnings <<- c(warnings, conditionMessage(w)); invokeRestart("muffleWarning")
        }
      )
    ),
    error = function(e) { error_msg <<- conditionMessage(e); character() }
  )
  if (!is.null(error_msg)) return(list(ok = FALSE, output = paste(printed, collapse = "\n"), error = error_msg))
  out <- printed
  vis <- box$vis
  # 可见返回值(且未被上面的 print 自动打印过——eval 不会自动打印,故这里补印)。
  if (is.list(vis) && isTRUE(vis$visible) && !is.null(vis$value)) {
    out <- c(out, utils::capture.output(print(vis$value)))
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
  # context() 也可能因 socket 已关闭抛错("Object closed")——整体 tryCatch,
  # 让陈旧/关闭的 socket 安全返回 NULL,不把异常抛给 later 回调。
  res <- tryCatch({
    ctx <- nanonext::context(sock)
    nanonext::reply(ctx, execute = function(req) {
      code <- if (is.list(req)) req$code else req
      cap <- .addin_run_r_capture(code, envir = envir)
      if (is.function(on_echo)) tryCatch(on_echo(as.character(code), cap), error = function(e) NULL)
      cap
    }, timeout = timeout)
  }, error = function(e) NULL)
  invisible(res)
}

# 把 Claude 执行的代码渲染成"经典 R console 输入"样式:`> `/`+ ` 提示符前缀 +
# 语法高亮(prettycode,交互 console 才显色)或蓝色(cli)兜底,纯文本最终兜底。
.addin_console_prompt_code <- function(code) {
  lines <- strsplit(paste(as.character(code), collapse = "\n"), "\n", fixed = TRUE)[[1]]
  if (!length(lines)) lines <- ""
  hl <- if (requireNamespace("prettycode", quietly = TRUE))
    tryCatch(as.character(prettycode::highlight(lines)), error = function(e) NULL) else NULL
  if (is.null(hl) || length(hl) != length(lines))
    hl <- if (requireNamespace("cli", quietly = TRUE)) cli::col_blue(lines) else lines
  prompts <- c("> ", rep("+ ", max(0L, length(hl) - 1L)))
  if (requireNamespace("cli", quietly = TRUE)) prompts <- cli::col_blue(prompts)
  paste0(prompts, hl)
}

# 回显行(可测):青色规则标题 + 提示符代码 + 报错(红)/正常输出(默认)。
.addin_console_echo_lines <- function(code, cap) {
  # 固定宽度青色分隔符(之前用 cli::rule 会画满整个 console 宽度 → 超长无意义)。
  header <- if (requireNamespace("cli", quietly = TRUE))
    cli::col_cyan(paste0("\u2500\u2500 Claude ran in console ", strrep("\u2500", 24L)))
  else "\u2500\u2500 Claude ran in console \u2500\u2500"
  lines <- c(header, .addin_console_prompt_code(code))
  if (!is.null(cap$error)) {
    e <- paste0("Error: ", cap$error)
    lines <- c(lines, if (requireNamespace("cli", quietly = TRUE)) cli::col_red(e) else e)
  } else if (nzchar(cap$output %||% "")) {
    lines <- c(lines, cap$output)
  }
  lines
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
    cat("\n", paste(.addin_console_echo_lines(code, cap), collapse = "\n"), "\n", sep = "")
  } else NULL
  service <- function() {
    # 守卫:server 已停(active=FALSE),或本循环持有的是被新 server 替换掉的
    # 陈旧 socket(重启/换目录重连时)→ 自我终止,不再轮询,避免用已关闭 socket 报错。
    if (!isTRUE(.claude_console_state$active) ||
        !identical(sock, .claude_console_state$socket)) return(invisible(NULL))
    .addin_console_service_once(sock, envir = envir, on_echo = echo_fn)
    later::later(service, 0.1)
  }
  later::later(service, 0.1)
  invisible(TRUE)
}

# Return one stable package-owned run_r endpoint for every background Chat and
# Workspace launched by this main R session. Repeated Addin invocations must not
# close/rebind the REP socket while an existing Job still depends on it.
.addin_ensure_r_console_server <- function(
    envir = globalenv(), echo = TRUE,
    url_factory = function() {
      paste0("ipc://", tempfile("claude-addin-console-", fileext = ".sock"))
    }) {
  valid_url <- function(value) {
    is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value)
  }
  current_url <- .claude_console_state$url
  if (isTRUE(.claude_console_state$active) &&
      !is.null(.claude_console_state$socket) && valid_url(current_url)) {
    return(current_url)
  }
  if (!requireNamespace("nanonext", quietly = TRUE) ||
      !requireNamespace("later", quietly = TRUE)) return(NULL)

  # Preserve the endpoint embedded in already-running Chat/Workspace specs.
  # Only allocate a replacement if rebinding our previous URL genuinely fails.
  if (valid_url(current_url)) {
    started <- isTRUE(tryCatch(
      .addin_start_r_console_server(current_url, envir = envir, echo = echo),
      error = function(e) FALSE
    ))
    if (started) return(current_url)
  }
  replacement <- tryCatch(as.character(url_factory())[[1L]], error = function(e) "")
  if (!valid_url(replacement) || identical(replacement, current_url)) return(NULL)
  started <- isTRUE(tryCatch(
    .addin_start_r_console_server(replacement, envir = envir, echo = echo),
    error = function(e) FALSE
  ))
  if (started) replacement else NULL
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


# ── Angle B (Plan 22): Claude-agentic run_r through an external stdio MCP ────
# Claude calls run_r → (approval) → inst/mcp/run_r_server.R routes over
# nanonext to the main-session env-server (above) → the code runs VISIBLY in
# the user's live .GlobalEnv (echo) and the capture is returned to Claude.
# Reuses the Angle A env-server and ClaudeAgentSDK's stdio-MCP support.

# autorun toggle → which allowed_tools to connect with. When on, run_r is
# auto-allowed (no approval card); when off, run_r hits the approval card.
.addin_run_r_allowed_tools <- function(autorun_on, base = NULL) {
  tool <- "mcp__r_session__run_r"
  if (!isTRUE(autorun_on)) return(base)
  if (tool %in% base) return(base)
  c(base, tool)
}

# run_r 开关(Plan 45):关掉时从连接选项的 mcp_servers 摘除 r_session(纯函数,可测)。
.filter_run_r_mcp <- function(mcp_servers, enabled) {
  if (!isTRUE(enabled) && is.list(mcp_servers) && "r_session" %in% names(mcp_servers))
    mcp_servers[["r_session"]] <- NULL
  mcp_servers
}

# Build the external stdio "r_session" MCP server config. It launches
# inst/mcp/run_r_server.R and routes requests to the live console server. The
# subprocess is curl-free (ClaudeAgentSDK + nanonext only); console_url and the
# library paths are passed via its environment. Returns NULL when the installed
# ClaudeAgentSDK lacks stdio-MCP support or the script is missing.
.addin_run_r_server <- function(console_url, timeout = 60000) {
  if (!requireNamespace("ClaudeAgentSDK", quietly = TRUE) ||
      !("mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK")))
    return(NULL)
  script <- system.file("mcp", "run_r_server.R", package = "shinyAssistantUI")
  if (!nzchar(script) || !file.exists(script)) return(NULL)
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  list(
    type    = "stdio",
    command = rscript,
    # --vanilla for a deterministic startup (no project .Rprofile/renv surprises);
    # R_LIBS in env still sets libPaths so ClaudeAgentSDK + nanonext are found.
    args    = list("--vanilla", script),
    env     = list(
      CLAUDE_ADDIN_CONSOLE_URL = console_url,
      R_LIBS                   = paste(.libPaths(), collapse = .Platform$path.sep)
    )
  )
}
