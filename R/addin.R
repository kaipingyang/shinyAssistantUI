# RStudio addin — Claude Code chat inside RStudio
# 在 RStudio(Viewer/对话框)里启动 shinyAssistantUI + ClaudeAgentSDK 聊天,以当前项目为根
# (cwd),让 Claude 的 Read/Edit/Bash 工具直接作用于用户的项目文件。上下文(当前文件/选区)
# 经 ClaudeAgentSDK::SystemPromptPreset(append=) 追加到 Claude Code 预设提示词(不覆盖)。
#
# `%||%` 已是包内函数(见 handlers.R),此处直接复用。

# 绝对路径 → 相对项目根(fixed=TRUE 避免正则/Windows 元字符问题;项目外则保留绝对)。
.rel_path <- function(path, project) {
  if (is.null(path) || !nzchar(path) || is.null(project) || !nzchar(project)) return(path)
  p  <- tryCatch(normalizePath(path, mustWork = FALSE),    error = function(e) path)
  pr <- tryCatch(normalizePath(project, mustWork = FALSE), error = function(e) project)
  pr_slash <- if (endsWith(pr, .Platform$file.sep)) pr else paste0(pr, .Platform$file.sep)
  if (startsWith(p, pr_slash)) substring(p, nchar(pr_slash) + 1L) else p
}

# 当前项目根:RStudio 项目 → 否则 getwd()。无 rstudioapi 时安全回落。
.addin_project <- function() {
  proj <- NULL
  if (requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) {
    proj <- tryCatch(rstudioapi::getActiveProject(), error = function(e) NULL)
  }
  if (is.null(proj) || !nzchar(proj)) getwd() else proj
}

# 活动编辑器上下文:list(path, rel, selection, first_line, last_line) 或 NULL。全程 guard。
# 点击文件引用 / Claude 编辑后揭示 → 在 RStudio 编辑器打开。
# 相对路径按 project 解析成绝对路径；若编辑器已聚焦同一文件则不重复跳转（避免抢焦点）。
.addin_open_file <- function(path, line = NULL, project = NULL) {
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) return(invisible(NULL))
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) return(invisible(NULL))

  abs_path <- path
  if (!isTRUE(startsWith(path, "/")) && !grepl("^[A-Za-z]:", path) && !is.null(project)) {
    abs_path <- file.path(project, path)
  }
  abs_path <- tryCatch(normalizePath(abs_path, winslash = "/", mustWork = FALSE),
                       error = function(e) abs_path)
  if (!file.exists(abs_path)) return(invisible(NULL))

  # 已聚焦同一文件则不跳转
  current <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) NULL)
  if (!is.null(current) && nzchar(current)) {
    current_norm <- tryCatch(normalizePath(current, winslash = "/", mustWork = FALSE),
                             error = function(e) current)
    if (identical(current_norm, abs_path)) return(invisible(NULL))
  }

  ln <- suppressWarnings(as.integer(line))
  if (length(ln) != 1L || is.na(ln) || ln < 1L) ln <- -1L
  tryCatch(rstudioapi::navigateToFile(abs_path, line = ln), error = function(e) NULL)
  invisible(NULL)
}

# 只采样第一段 selection，确保文本与行范围属于同一个选区。
.addin_editor_context <- function(project = NULL) {
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) return(NULL)
  ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
  if (is.null(ctx)) return(NULL)
  path <- tryCatch(ctx$path, error = function(e) "")
  if (is.null(path) || !nzchar(path)) path <- NULL
  ranges <- tryCatch(ctx$selection, error = function(e) NULL)
  sel <- ""; a <- NULL; b <- NULL
  if (length(ranges)) {
    first <- ranges[[1L]]
    sel <- tryCatch(first$text %||% "", error = function(e) "")
    rg <- tryCatch(first$range, error = function(e) NULL)
    if (!is.null(rg)) { a <- tryCatch(rg$start[[1]], error = function(e) NULL)
                        b <- tryCatch(rg$end[[1]],   error = function(e) NULL) }
  }
  if (is.null(path) && !nzchar(sel)) return(NULL)
  list(path = path, rel = if (!is.null(path)) .rel_path(path, project) else NULL,
       selection = if (nzchar(sel)) sel else NULL, first_line = a, last_line = b)
}

# git ls-files -z 的 NUL-safe 解码。system2(stdout=TRUE) 按行读取会破坏含换行的
# 合法文件名，因此先写 raw 临时文件再按 NUL 切分。
.read_nul_paths <- function(path) {
  size <- file.info(path)$size
  if (is.na(size) || size <= 0) return(character(0))
  raw <- readBin(path, what = "raw", n = size)
  ends <- which(raw == as.raw(0L))
  if (!length(ends)) return(character(0))
  starts <- c(1L, head(ends, -1L) + 1L)
  keep <- ends > starts
  vapply(which(keep), function(i) rawToChar(raw[starts[[i]]:(ends[[i]] - 1L)]), character(1))
}

# 构建 tracked + untracked、遵守 gitignore/global excludes 的 workspace index。
# 非 Git 项目诚实返回空列表，不用 list.files() 冒充 ignore-aware 结果。
.addin_workspace_index <- function(project, max_files = 10000L) {
  if (Sys.which("git") == "" || is.null(project) || !dir.exists(project)) return(list())
  project <- normalizePath(project, mustWork = TRUE)
  out <- tempfile("claude-workspace-", fileext = ".nul")
  err <- tempfile("claude-workspace-", fileext = ".err")
  on.exit(unlink(c(out, err)), add = TRUE)
  status <- suppressWarnings(tryCatch(
    system2(
      "git",
      c("-C", shQuote(project), "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
      stdout = out, stderr = err
    ),
    error = function(e) 1L
  ))
  if (!identical(as.integer(status), 0L)) return(list())

  files <- .read_nul_paths(out)
  files <- gsub("\\\\", "/", files)
  files <- files[nzchar(files) & !grepl("^(?:/|[A-Za-z]:|\\.\\.(?:/|$))", files)]
  files <- head(sort(unique(files)), max(0L, as.integer(max_files)))

  # 文件夹推导：先收集到 list（避免循环内 c() 的 O(n^2) 累加），最后一次 unique。
  folder_lists <- lapply(files, function(file) {
    acc <- character(0)
    parent <- dirname(file)
    while (!identical(parent, ".") && nzchar(parent)) {
      acc <- c(acc, paste0(parent, "/"))
      next_parent <- dirname(parent)
      if (identical(next_parent, parent)) break
      parent <- next_parent
    }
    acc
  })
  folders <- sort(unique(unlist(folder_lists, use.names = FALSE)))
  c(
    lapply(folders, function(path) list(kind = "folder", path = path)),
    lapply(files, function(path) list(kind = "file", path = path))
  )
}

# git HEAD 指纹（用于 workspace 索引缓存失效）。非 git/detached/空仓返回 NULL → 不缓存。
.addin_git_head <- function(project) {
  if (Sys.which("git") == "" || is.null(project) || !dir.exists(project)) return(NULL)
  head <- suppressWarnings(tryCatch(
    system2("git", c("-C", shQuote(project), "rev-parse", "HEAD"),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)
  ))
  head <- head[nzchar(head)]
  if (!length(head)) NULL else head[[1L]]
}

# 带缓存的 workspace 索引：按 normalizePath(project)+git HEAD 缓存到 home 的 rds。
# 命中直接读，HEAD 变化或非 git 时重建（非 git 不写缓存）。
.addin_workspace_index_cached <- function(project, cache_path, max_files = 10000L) {
  head <- .addin_git_head(project)
  key <- tryCatch(normalizePath(project, winslash = "/", mustWork = FALSE),
                  error = function(e) as.character(project))
  if (!is.null(head) && file.exists(cache_path)) {
    store <- tryCatch(readRDS(cache_path), error = function(e) list())
    entry <- if (is.list(store)) store[[key]] else NULL
    if (is.list(entry) && identical(entry$head, head) && is.list(entry$index)) {
      return(entry$index)
    }
  }
  index <- .addin_workspace_index(project, max_files = max_files)
  if (!is.null(head)) {
    store <- if (file.exists(cache_path)) tryCatch(readRDS(cache_path), error = function(e) list()) else list()
    if (!is.list(store)) store <- list()
    store[[key]] <- list(head = head, index = index)
    tryCatch(.atomic_save_rds(store, cache_path), error = function(e) NULL)
  }
  index
}

.addin_fuzzy_match <- function(needle, haystack) {
  if (!nzchar(needle)) return(TRUE)
  chars <- strsplit(needle, "", fixed = TRUE)[[1L]]
  text <- strsplit(haystack, "", fixed = TRUE)[[1L]]
  pos <- 1L
  for (ch in chars) {
    if (pos > length(text)) return(FALSE)
    found <- which(text[seq.int(pos, length(text))] == ch)
    if (!length(found)) return(FALSE)
    pos <- pos + found[[1L]]
  }
  TRUE
}

.addin_mention_insert_text <- function(path) {
  if (grepl("[[:space:]]", path)) paste0('@"', gsub('"', '\\"', path, fixed = TRUE), '"')
  else paste0("@", path)
}

# 确定性 fuzzy 排序：basename prefix/substring > path prefix/substring >
# subsequence；同分时浅层路径、folder、短路径、字典序优先。
.addin_workspace_search <- function(index, query = "", kinds = c("file", "folder"), limit = 50L) {
  query <- tolower(trimws(query %||% ""))
  kinds <- intersect(as.character(kinds %||% c("file", "folder")), c("file", "folder"))
  if (!length(kinds)) return(list())
  candidates <- Filter(function(x) is.list(x) && x$kind %in% kinds && nzchar(x$path %||% ""), index)
  scored <- lapply(candidates, function(item) {
    path <- tolower(item$path)
    base <- tolower(basename(sub("/$", "", item$path)))
    score <- if (!nzchar(query)) 0L
      else if (startsWith(base, query)) 0L
      else if (grepl(query, base, fixed = TRUE)) 1L
      else if (startsWith(path, query)) 2L
      else if (grepl(query, path, fixed = TRUE)) 3L
      else if (.addin_fuzzy_match(query, base)) 4L
      else if (.addin_fuzzy_match(query, path)) 5L
      else Inf
    if (!is.finite(score)) return(NULL)
    depth <- lengths(regmatches(item$path, gregexpr("/", item$path, fixed = TRUE)))
    c(item, list(
      label = basename(sub("/$", "", item$path)),
      insertText = .addin_mention_insert_text(item$path),
      .score = score, .depth = depth
    ))
  })
  scored <- Filter(Negate(is.null), scored)
  if (!length(scored)) return(list())
  ord <- order(
    vapply(scored, `[[`, numeric(1), ".score"),
    vapply(scored, `[[`, integer(1), ".depth"),
    vapply(scored, function(x) if (identical(x$kind, "folder")) 0L else 1L, integer(1)),
    vapply(scored, function(x) nchar(x$path), integer(1)),
    vapply(scored, `[[`, character(1), "path")
  )
  result <- head(scored[ord], max(1L, min(100L, as.integer(limit %||% 50L))))
  lapply(result, function(x) x[setdiff(names(x), c(".score", ".depth"))])
}

.make_addin_workspace_search_provider <- function(project, cache_path = NULL) {
  cache_path <- cache_path %||% file.path(
    Sys.getenv("HOME", unset = "~"), ".claude_addin_workspace_cache.rds")
  index <- .addin_workspace_index_cached(project, cache_path)
  function(query = "", kinds = c("file", "folder"), limit = 50L) {
    .addin_workspace_search(index, query = query, kinds = kinds, limit = limit)
  }
}

# 纯函数:把编辑器上下文拼成要 append 到 Claude Code 预设提示词的文本。
# selection 截断到 ~4000 字符,避免提示词膨胀。
.addin_context_text <- function(ctx, project) {
  lines <- c(paste0("You are assisting a user inside the RStudio IDE.",
                    " Project root (your working directory): ", project, "."))
  if (!is.null(ctx)) {
    if (!is.null(ctx$rel))
      lines <- c(lines, paste0("The user's active editor file is `", ctx$rel, "`."))
    if (!is.null(ctx$selection)) {
      sel <- ctx$selection
      if (nchar(sel) > 4000L) sel <- paste0(substr(sel, 1L, 4000L), "\n... (truncated)")
      loc <- if (!is.null(ctx$first_line) && !is.null(ctx$last_line))
        paste0(" (lines ", ctx$first_line, "-", ctx$last_line, ")") else ""
      lines <- c(lines,
                 paste0("They have selected this code", loc, ":\n```\n", sel, "\n```"))
    }
  }
  lines <- c(lines,
             paste0("Use your file tools (Read/Edit/Bash/Grep) on the project as needed;",
                    " prefer paths relative to the project root."))
  paste(lines, collapse = "\n")
}

# Addin 专用全屏 UI：fillPage 建立 html/body 的 100% 高度链，但不加载
# Bootstrap，避免其全局样式覆盖 widget 内的 Tailwind/shadcn 组件。
.claude_chat_ui <- function() {
  assistantUIPage(
    assistantUIOutput("chat", height = "100%")
  )
}

#' Build the Claude Code chat app (internal, RStudio-free so it is unit/browser testable)
#'
#' @param project Project root used as Claude's working directory.
#' @param ctx Deprecated startup context retained for internal compatibility.
#'   Live context is sampled by `ide_context_provider` for each new submission.
#' @param options Optional [ClaudeAgentSDK::ClaudeAgentOptions]; a project-rooted default with
#'   the context appended to the Claude Code preset system prompt is built when `NULL`.
#' @param permission_mode Claude permission mode: `"default"` (approval cards),
#'   `"plan"` (read-only planning), `"acceptEdits"` (auto-approve file edits,
#'   prompt shell), or `"bypassPermissions"` (no prompts). Ignored when
#'   `options` is supplied.
#' @param prewarm Passed to [assistantUIServer()] (default `FALSE`).
#' @return A [shiny::shinyApp] object.
#' @keywords internal
#' @noRd
.claude_action_items <- function() {
  list(
    list(section = "Context", id = "context", command = "context",
         label = "Context usage", description = "Show current context-window usage"),
    list(section = "Context", id = "compact", command = "compact",
         label = "Compact conversation", description = "Summarize this conversation to free context"),
    list(section = "Context", id = "clear", command = "clear",
         label = "New conversation", description = "Clear this conversation and start fresh"),
    list(section = "Customize", id = "mcp", command = "mcp",
         label = "MCP status", description = "Show connected MCP servers")
  )
}

.claude_chat_app <- function(project, ctx = NULL, options = NULL,
                              permission_mode = "default", prewarm = FALSE) {
  if (!requireNamespace("ClaudeAgentSDK", quietly = TRUE))
    stop("The Claude Code addin needs the 'ClaudeAgentSDK' package. Install it first.",
         call. = FALSE)
  if (is.null(options)) {
    options <- ClaudeAgentSDK::ClaudeAgentOptions(
      cwd                         = project,
      system_prompt               = ClaudeAgentSDK::SystemPromptPreset(
        append = .addin_context_text(NULL, project)),
      permission_mode             = permission_mode,
      permission_prompt_tool_name = "stdio",
      include_partial_messages    = TRUE
    )
  }
  # session_map stored in user home to survive project switches
  session_map_path <- file.path(
    Sys.getenv("HOME", unset = "~"), ".claude_addin_session_map.rds")
  # 归档软隐藏存储（per-project，存于 home 以跨会话保留）
  archived_path <- file.path(
    Sys.getenv("HOME", unset = "~"), ".claude_addin_archived.rds")
  handler <- make_claude_handler(
    options          = options,
    session_map_path = session_map_path
  )
  skills <- tryCatch(load_claude_skills(project_dir = project), error = function(e) list())
  workspace_search <- .make_addin_workspace_search_provider(project)

  ui <- .claude_chat_ui()
  server <- function(input, output, session) {
    # runGadget(stopOnCancel = TRUE) implements cancellation by deliberately
    # raising "User cancel". Shiny invokes options(shiny.error) before an outer
    # tryCatch can catch that error, which opens RStudio's debugger. Handle the
    # same input as a normal stopApp return instead.
    shiny::observeEvent(input$cancel, {
      .stop_claude_gadget_normally()
    }, ignoreInit = TRUE)

    ctrl <- assistantUIServer(
      "chat", handler = handler,
      show_thread_list = TRUE,
      persistence      = "server",
      on_session_load  = make_claude_session_loader(session_map_path = session_map_path),
      commands         = skills,
      action_items     = .claude_action_items(),
      on_open_file     = function(path, line = NULL) .addin_open_file(path, line, project),
      on_archive_session = function(session_id, archived) {
        # 仅服务端持久化软隐藏；前端已本地乐观更新（移入/移出归档区）。
        # 不再重推会话列表——重推会把"当前对话已生成的 server session"与其客户端新线程
        # 双显（同标题两条）。重开时初始推送（带 archived 标记）才是权威来源。
        .toggle_archived_id(archived_path, project, session_id, archived)
      },
      on_delete_session = function(session_id) {
        # Delete 真删磁盘 transcript（不可逆）+ 清归档/映射记录。前端已本地移除该项；
        # 同样不重推（避免当前对话重复）。
        tryCatch(ClaudeAgentSDK::delete_session(session_id, directory = project),
                 error = function(e) NULL)
        .toggle_archived_id(archived_path, project, session_id, FALSE)
        tryCatch(.remove_claude_session_map(session_map_path, session_id),
                 error = function(e) NULL)
      },
      ide_context_provider = function() .addin_editor_context(project),
      workspace_search_provider = workspace_search,
      prewarm          = prewarm
    )

    # 统一的会话推送：带 archived 标记（服务端权威）。闭包惰性引用 ctrl（用户点击时
    # 才运行，ctrl 已赋值）。
    push_sessions <- function() {
      ctrl$send_sessions(list(
        sessions = list_claude_sessions(
          directory = project,
          archived_ids = .read_archived_ids(archived_path, project)
        )
      ))
    }

    # on_session_load 只负责用户点击后加载消息；侧栏列表必须另行注入。
    # assistantUIServer 会缓存首次发送，并在前端 :sessions handler ready 后补发，
    # 因而这里可在初始 reactive flush 中安全发送。
    shiny::observe({
      push_sessions()
    })
  }
  shiny::shinyApp(ui, server)
}

# Stop the gadget with a normal NULL return. This is deliberately separate so
# the input$cancel path is testable without mutating Shiny's global run state.
.stop_claude_gadget_normally <- function() {
  shiny::stopApp()
}

# Run an addin gadget while treating IDE-driven cancellation as normal shutdown.
# stopOnCancel = FALSE is essential: Shiny's default creates stop("User cancel")
# inside a calling handler, which reaches options(shiny.error) (and therefore the
# RStudio debugger) before this outer tryCatch can see it.
.run_claude_gadget <- function(app, viewer, run_gadget = shiny::runGadget) {
  tryCatch(
    run_gadget(app, viewer = viewer, stopOnCancel = FALSE),
    interrupt = function(e) NULL,
    error = function(e) {
      # Retain compatibility with injected/older runners that may still return
      # the historical cancellation condition.
      if (identical(conditionMessage(e), "User cancel")) return(NULL)
      stop(e)
    }
  )
}

#' Open a Claude Code chat inside RStudio
#'
#' Launches the shinyAssistantUI chat (backed by ClaudeAgentSDK) in the RStudio Viewer pane or a
#' dialog, rooted at the current project so Claude's agentic tools (Read/Edit/Bash/Grep) act on
#' your project files. The active editor file and any selection are sampled again for each new
#' prompt (rather than frozen at startup); the composer can hide selection text while keeping the
#' active-file reference, so you can ask "explain this" / "refactor the selection".
#'
#' Thread history is stored in `~/.claude_addin_session_map.rds` (user home, not the project),
#' so conversations persist across project switches and RStudio restarts.
#'
#' Registered as the RStudio addin **"Claude Code Chat"**; also callable programmatically.
#'
#' @param project Project root (Claude's working directory). Defaults to the active RStudio
#'   project, else [getwd()].
#' @param viewer Where to show the gadget: `"pane"` (Viewer pane, default), `"dialog"`, or
#'   `"browser"`. Forced to `"browser"` when not running in RStudio.
#' @param permission_mode Claude tool-use permission policy:
#'   \describe{
#'     \item{`"default"`}{File edits and shell commands require per-action approval via the
#'       in-chat approval card (safest — recommended for shared/production projects).}
#'     \item{`"plan"`}{Read-only analysis and planning; edits are not permitted.}
#'     \item{`"acceptEdits"`}{File edits are auto-approved; shell commands still prompt.}
#'     \item{`"bypassPermissions"`}{All tool calls run without prompts (fastest, use with care).}
#'   }
#'   Ignored when `options` is supplied directly.
#' @param prewarm Logical (default `FALSE`). If `TRUE`, pre-connect the Claude CLI at launch so
#'   the first message isn't slowed by the cold start (see [assistantUIServer()]).
#' @param options Optional [ClaudeAgentSDK::ClaudeAgentOptions] to fully override all defaults.
#' @return Invisibly, the result of [shiny::runGadget()].
#' @export
#' @examples
#' \dontrun{
#'   # From the RStudio Addins menu: "Claude Code Chat", or:
#'   claude_addin()
#'   claude_addin(permission_mode = "acceptEdits")   # auto-approve file edits
#'   claude_addin(viewer = "dialog")                 # floating dialog instead of pane
#' }
claude_addin <- function(project         = NULL,
                         viewer          = c("pane", "dialog", "browser"),
                         permission_mode = c("default", "plan", "acceptEdits", "bypassPermissions"),
                         prewarm         = FALSE,
                         options         = NULL) {
  viewer          <- match.arg(viewer)
  permission_mode <- match.arg(permission_mode)
  project <- project %||% .addin_project()
  app <- .claude_chat_app(project, options = options,
                          permission_mode = permission_mode, prewarm = prewarm)

  in_rstudio <- requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))
  vw <- if (!in_rstudio) shiny::browserViewer()
        else switch(viewer,
                    pane    = shiny::paneViewer(minHeight = 600),
                    dialog  = shiny::dialogViewer("Claude Code", width = 1000, height = 800),
                    browser = shiny::browserViewer())
  invisible(.run_claude_gadget(app, vw))
}
