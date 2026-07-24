# RStudio addin — Claude Code chat inside RStudio
# 在 RStudio(Viewer/对话框)里启动 shinyAssistantUI + ClaudeAgentSDK 聊天,以当前项目为根
# (cwd),让 Claude 的 Read/Edit/Bash 工具直接作用于用户的项目文件。上下文(当前文件/选区)
# 经 ClaudeAgentSDK::SystemPromptPreset(append=) 追加到 Claude Code 预设提示词(不覆盖)。
#
# 本文件仅保留 orchestrator（claude_addin / .claude_chat_app / .addin_project / gadget runner）。
# IDE 上下文见 addin-context.R；workspace 搜索见 addin-workspace.R；UI/动作项见 addin-ui.R。
# `%||%` 已是包内函数(见 handlers.R),此处直接复用。

# ── addin 持久化存储：统一放 ~/.claude_addin/ 目录（原来散落 $HOME 根） ──────────
.claude_addin_dir <- function(home = Sys.getenv("HOME", unset = "~")) {
  file.path(home, ".claude_addin")
}
.claude_addin_path <- function(name, home = Sys.getenv("HOME", unset = "~")) {
  file.path(.claude_addin_dir(home), name)
}
# 把 RStudio Files 面板导航到某目录（纯前端 rstudioapi 调用，gadget 占用 console 也生效）。
# rstudioapi 不可用/无该函数/非目录时安全无操作。抽出以便复用（切目录 + 开启同步时）与测试。
.addin_files_pane_navigate <- function(path) {
  if (is.null(path) || !nzchar(path)) return(invisible(FALSE))
  ok <- requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE)) &&
    isTRUE(tryCatch(rstudioapi::hasFun("filesPaneNavigate"), error = function(e) FALSE))
  if (!ok) return(invisible(FALSE))
  tryCatch({ rstudioapi::filesPaneNavigate(path); TRUE },
           error = function(e) FALSE)
}
# 一次性迁移：把旧的 ~/.claude_addin_*.rds 搬进 ~/.claude_addin/<name>.rds。
# 新文件已存在则不覆盖（保护当前数据）。启动时调用一次。
.migrate_addin_storage <- function(home = Sys.getenv("HOME", unset = "~")) {
  dir <- .claude_addin_dir(home)
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  moves <- list(
    c(".claude_addin_session_map.rds",     "session_map.rds"),
    c(".claude_addin_archived.rds",        "archived.rds"),
    c(".claude_addin_workspace_cache.rds", "workspace_cache.rds"),
    c(".claude_addin_recent_dirs.rds",     "recent_dirs.rds"),
    c(".claude_addin_projects.rds",        "projects.rds")
  )
  for (m in moves) {
    old <- file.path(home, m[[1]]); new <- file.path(dir, m[[2]])
    if (file.exists(old) && !file.exists(new)) {
      ok <- isTRUE(tryCatch(file.rename(old, new), error = function(e) FALSE))
      if (!ok) tryCatch({ file.copy(old, new, overwrite = FALSE); file.remove(old) },
                        error = function(e) NULL)
    }
  }
  invisible(dir)
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
.claude_chat_app <- function(project, ctx = NULL, options = NULL,
                              permission_mode = "default", prewarm = FALSE,
                              models = NULL) {
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
  .migrate_addin_storage()
  # session_map stored in user home to survive project switches
  session_map_path <- .claude_addin_path("session_map.rds")
  # 归档软隐藏存储（per-project，存于 home 以跨会话保留）
  archived_path <- .claude_addin_path("archived.rds")
  # 当前工作目录（可切换）。用普通环境持有，cwd_provider 在连接时读取；工作目录选择器
  # （Phase 3b）改它并触发 reset_clients + 重推 sessions。默认 = 初始 project。
  dir_state <- new.env(parent = emptyenv())
  dir_state$cwd <- project
  cur_dir <- function() dir_state$cwd
  # Files 面板跟随偏好（持久化，默认 TRUE）：切目录时是否同步 RStudio Files 面板。
  follow_pref <- new.env(parent = emptyenv())
  follow_pref$on <- {
    p <- .claude_addin_path("follow_files.rds")
    v <- if (file.exists(p)) tryCatch(readRDS(p), error = function(e) TRUE) else TRUE
    if (is.logical(v) && length(v) == 1L && !is.na(v)) v else TRUE
  }
  handler <- make_claude_handler(
    options          = options,
    cwd_provider     = cur_dir,
    models           = models,
    session_map_path = session_map_path
  )
  skills <- tryCatch(load_claude_skills(project_dir = cur_dir()), error = function(e) list())
  workspace_search <- .make_addin_workspace_search_provider(cur_dir)

  ui <- .claude_chat_ui()
  server <- function(input, output, session) {
    # runGadget(stopOnCancel = TRUE) implements cancellation by deliberately
    # raising "User cancel". Shiny invokes options(shiny.error) before an outer
    # tryCatch can catch that error, which opens RStudio's debugger. Handle the
    # same input as a normal stopApp return instead.
    shiny::observeEvent(input$cancel, {
      .stop_claude_gadget_normally()
    }, ignoreInit = TRUE)

    # 工作目录选择器：RStudio 有原生目录弹窗；apply_working_dir 由下方定义（惰性引用 ctrl/push_sessions）。
    native_picker <- requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))
    on_pick_wd <- function() {
      if (!native_picker) return(invisible(NULL))
      d <- tryCatch(rstudioapi::selectDirectory(caption = "Select working directory",
                                                path = dir_state$cwd),
                    error = function(e) NULL)
      if (!is.null(d) && nzchar(d)) apply_working_dir(d)
    }
    on_set_wd <- function(path) apply_working_dir(path)

    # 收藏夹（持久化 home）。保存当前目录 / 删除，改后回推列表。apply/ctrl 惰性引用。
    projects_path <- .claude_addin_path("projects.rds")
    on_save_project <- function() {
      ctrl$send_projects(.add_saved_project(projects_path, dir_state$cwd))
    }
    on_remove_project <- function(path) {
      ctrl$send_projects(.remove_saved_project(projects_path, path))
    }

    ctrl <- assistantUIServer(
      "chat", handler = handler,
      show_thread_list = TRUE,
      persistence      = "server",
      working_dir      = cur_dir(),
      native_picker    = native_picker,
      on_pick_working_dir = on_pick_wd,
      on_set_working_dir  = on_set_wd,
      projects          = .read_saved_projects(.claude_addin_path("projects.rds")),
      on_save_project   = on_save_project,
      on_remove_project = on_remove_project,
      files_pane_follow = if (native_picker) follow_pref$on else NULL,
      on_toggle_files_pane_follow = function(v) {
        follow_pref$on <- isTRUE(v)
        tryCatch(saveRDS(follow_pref$on, .claude_addin_path("follow_files.rds")),
                 error = function(e) NULL)
        # 刚开启 → 立即把 Files 面板跟到当前目录（Bug2：开启动作本身也导航）。
        if (isTRUE(v)) .addin_files_pane_navigate(dir_state$cwd)
      },
      on_session_load  = make_claude_session_loader(session_map_path = session_map_path),
      commands         = skills,
      action_items     = .claude_action_items(),
      on_open_file     = function(path, line = NULL) .addin_open_file(path, line, cur_dir()),
      on_edits         = function(edits) .addin_show_edit_markers(edits, cur_dir()),
      on_rename        = function(thread_id, title)
        .claude_rename_session(thread_id, title, session_map_path, cur_dir()),
      on_archive_session = function(session_id, archived) {
        # 仅服务端持久化软隐藏；前端已本地乐观更新（移入/移出归档区）。
        # 不再重推会话列表——重推会把"当前对话已生成的 server session"与其客户端新线程
        # 双显（同标题两条）。重开时初始推送（带 archived 标记）才是权威来源。
        .toggle_archived_id(archived_path, cur_dir(), session_id, archived)
      },
      on_delete_session = function(session_id) {
        # 删前断开该 session 的 client（避免 CLI 写回）；真删失败不再静默——重推让它重现。
        .claude_delete_session(
          session_id, project = cur_dir(), handler = handler,
          archived_path = archived_path, session_map_path = session_map_path,
          on_reappear = function() tryCatch(push_sessions(), error = function(e) NULL)
        )
      },
      ide_context_provider = function() {
        # 提交前保存活动文档（有路径的；untitled 跳过）→ Claude 编辑基于最新、且不丢未保存改动。
        .addin_save_dirty_docs()
        .addin_editor_context(cur_dir())
      },
      workspace_search_provider = workspace_search,
      prewarm          = prewarm
    )

    # 统一的会话推送：带 archived 标记（服务端权威）。闭包惰性引用 ctrl（用户点击时
    # 才运行，ctrl 已赋值）。按当前工作目录 cur_dir() 分桶。
    push_sessions <- function() {
      ctrl$send_sessions(list(
        sessions = list_claude_sessions(
          directory = cur_dir(),
          archived_ids = .read_archived_ids(archived_path, cur_dir())
        )
      ))
    }

    # on_session_load 只负责用户点击后加载消息；侧栏列表必须另行注入。
    # assistantUIServer 会缓存首次发送，并在前端 :sessions handler ready 后补发，
    # 因而这里可在初始 reactive flush 中安全发送。
    shiny::observe({
      push_sessions()
    })

    # 最近工作目录（存 home，跨会话保留；最近在前，上限 8）。
    recent_path <- .claude_addin_path("recent_dirs.rds")
    read_recent <- function() {
      if (!file.exists(recent_path)) return(character(0))
      v <- tryCatch(readRDS(recent_path), error = function(e) character(0))
      if (is.character(v)) v else character(0)
    }
    add_recent <- function(d) {
      r <- utils::head(unique(c(d, read_recent())), 8L)
      tryCatch(.atomic_save_rds(r, recent_path), error = function(e) NULL)
      r
    }

    # 切换工作目录：校验 → 改 cwd → 断开所有 client（换目录=全部重连）→ 先发 :working-dir
    # （前端据此清本次实例本地线程）→ 再重推该目录 sessions（替换列表）。无效/未变则 no-op。
    apply_working_dir <- function(new_dir) {
      if (is.null(new_dir) || !nzchar(new_dir)) return(invisible(NULL))
      nd <- tryCatch(normalizePath(new_dir, winslash = "/", mustWork = FALSE),
                     error = function(e) new_dir)
      if (!dir.exists(nd)) return(invisible(NULL))
      # 显式点选目录：只要同步开就刷新 Files 面板——即使还是当前目录（Bug2）。
      if (isTRUE(follow_pref$on)) .addin_files_pane_navigate(nd)
      if (identical(nd, dir_state$cwd)) return(invisible(nd))   # cwd 未变 → 跳过重连/收藏/推送
      dir_state$cwd <- nd
      tryCatch(attr(handler, "reset_clients")(), error = function(e) NULL)
      recent <- add_recent(nd)
      ctrl$send_working_dir(nd, as.list(recent))
      push_sessions()
      invisible(nd)
    }
  }
  shiny::shinyApp(ui, server)
}

# 删除一个会话：先断开仍连着它的 client（否则 CLI 会把 transcript 写回 → 删了又出现），
# 再真删磁盘 transcript。删除失败**不静默**：warning + on_reappear（重推列表，让该会话重新出现，
# 诚实反馈而非假装删了）。成功才清归档/映射。返回 TRUE/FALSE。
.claude_delete_session <- function(session_id, project, handler,
                                   archived_path, session_map_path,
                                   on_reappear = function() invisible(NULL)) {
  tryCatch(attr(handler, "release_session")(session_id), error = function(e) NULL)
  ok <- tryCatch({ .delete_claude_session(session_id, directory = project); TRUE },
                 error = function(e) {
                   warning("[CLAUDE] delete_session failed: ", conditionMessage(e), call. = FALSE)
                   FALSE
                 })
  if (isTRUE(ok)) {
    .toggle_archived_id(archived_path, project, session_id, FALSE)
    tryCatch(.remove_claude_session_map(session_map_path, session_id), error = function(e) NULL)
  } else {
    tryCatch(on_reappear(), error = function(e) NULL)
  }
  invisible(ok)
}

# ── 工作目录收藏夹（persistent，跨会话）：字符向量，最近保存在前、去重。─────────────
.read_saved_projects <- function(path) {
  if (!file.exists(path)) return(character(0))
  v <- tryCatch(readRDS(path), error = function(e) character(0))
  if (is.character(v)) v else character(0)
}
.add_saved_project <- function(path, dir) {
  if (is.null(dir) || !nzchar(dir)) return(invisible(.read_saved_projects(path)))
  cur <- .read_saved_projects(path)
  next_ids <- unique(c(as.character(dir), cur))   # 前插 + 去重
  tryCatch(.atomic_save_rds(next_ids, path), error = function(e) NULL)
  invisible(next_ids)
}
.remove_saved_project <- function(path, dir) {
  next_ids <- setdiff(.read_saved_projects(path), as.character(dir))
  tryCatch(.atomic_save_rds(next_ids, path), error = function(e) NULL)
  invisible(next_ids)
}

# 侧栏重命名 → 同步到 SDK session 存储（server 模式重开标题不丢）。按 thread 反查 session_id；
# 无映射（未生成 session 的新对话）则 no-op。返回 TRUE/FALSE。
.claude_rename_session <- function(thread_id, title, session_map_path, directory = NULL) {
  sid <- tryCatch(.read_claude_session_map(session_map_path)[[thread_id]], error = function(e) NULL)
  if (is.null(sid) || !nzchar(sid %||% "") || is.null(title) || !nzchar(title)) return(invisible(FALSE))
  ok <- tryCatch({ .rename_claude_session(sid, title, directory = directory); TRUE },
                 error = function(e) FALSE)
  invisible(ok)
}

# A5：把本轮编辑构建成 rstudioapi::sourceMarkers 的 markers 列表（去重、相对转绝对、file 级）。
# 纯函数，便于单测。edits = list(list(path=...), ...)。
.addin_edit_markers <- function(edits, project) {
  if (!length(edits)) return(list())
  paths <- unique(vapply(edits, function(e) as.character(e$path %||% ""), character(1)))
  paths <- paths[nzchar(paths)]
  lapply(paths, function(p) {
    abs_path <- if (isTRUE(startsWith(p, "/")) || grepl("^[A-Za-z]:", p) || is.null(project) || !nzchar(project))
      p else file.path(project, p)
    list(type = "info", file = abs_path, line = 1L, column = 1L, message = "Edited by Claude")
  })
}

# 把本轮编辑推进 RStudio Markers 面板（可点击跳转）。非 RStudio/空则 no-op。
.addin_show_edit_markers <- function(edits, project) {
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))) return(invisible(NULL))
  markers <- .addin_edit_markers(edits, project)
  if (!length(markers)) return(invisible(NULL))
  tryCatch(
    rstudioapi::sourceMarkers(name = "Claude edits", markers = markers,
                              basePath = project, autoSelect = "none"),
    error = function(e) NULL
  )
  invisible(NULL)
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

# ── Background-job launcher (Plan 20) ────────────────────────────────────────
# 选一个空闲端口：httpuv::randomPort 优先,否则安全区间随机(排除已知不安全端口)。
.claude_random_port <- function() {
  if (requireNamespace("httpuv", quietly = TRUE) &&
      isTRUE(tryCatch(is.function(httpuv::randomPort), error = function(e) FALSE))) {
    p <- tryCatch(httpuv::randomPort(), error = function(e) NA_integer_)
    if (!is.na(p)) return(as.integer(p))
  }
  unsafe <- c(3659, 4045, 5060, 5061, 6000, 6566, 6665:6669, 6697)
  as.integer(sample(setdiff(3000:8000, unsafe), 1L))
}

# TCP 层轮询端口就绪(job 里的 Shiny 起来没)。可注入用于测试。
.claude_wait_for_port <- function(host, port, timeout = 30, interval = 0.25) {
  deadline <- Sys.time() + timeout
  repeat {
    ok <- isTRUE(tryCatch({
      con <- socketConnection(host = host, port = port, server = FALSE,
                              blocking = TRUE, open = "r+", timeout = 1)
      close(con); TRUE
    }, warning = function(w) FALSE, error = function(e) FALSE))
    if (ok) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}

# 生成 background job 脚本文本：注入主会话 libPaths(让 job 能加载 shinyAssistantUI,
# 含外部库/renv)、library、再调 .claude_run_in_job 起 app。纯函数,便于单测。
.claude_bg_launch_script <- function(spec_path, port, host, libpaths) {
  c(
    sprintf(".libPaths(%s)", paste(deparse(as.character(libpaths)), collapse = "")),
    "library(shinyAssistantUI)",
    sprintf("shinyAssistantUI:::.claude_run_in_job(%s, port = %dL, host = %s)",
            deparse(spec_path), as.integer(port), deparse(host))
  )
}

# 在 job 进程里运行：读参数 → 构建同一个 .claude_chat_app → runApp(非阻塞浏览器)。
.claude_run_in_job <- function(spec_path, port, host = "127.0.0.1") {
  spec <- readRDS(spec_path)
  app <- .claude_chat_app(
    project         = spec$project,
    options         = spec$options,
    permission_mode = spec$permission_mode %||% "default",
    prewarm         = isTRUE(spec$prewarm),
    models          = spec$models
  )
  shiny::runApp(app, port = as.integer(port), host = host, launch.browser = FALSE)
}

# 主会话侧：序列化参数 → 写 job 脚本 → jobRunScript → 轮询就绪 → 在 Viewer 显示。
# job_run / show_viewer / wait_ready / port 均可注入,使主会话逻辑无需真实 RStudio 即可单测。
.run_claude_bg_job <- function(spec, host = "127.0.0.1", port = NULL,
                               libpaths = .libPaths(),
                               job_run = NULL, show_viewer = NULL,
                               wait_ready = .claude_wait_for_port) {
  port <- as.integer(port %||% .claude_random_port())
  spec_path <- tempfile("claude-addin-spec-", fileext = ".rds")
  saveRDS(spec, spec_path)
  script_path <- tempfile("claude-addin-job-", fileext = ".R")
  writeLines(.claude_bg_launch_script(spec_path, port, host, libpaths), script_path)

  job_run <- job_run %||% function(path, name, workingDir)
    tryCatch(
      rstudioapi::jobRunScript(path, name = name, workingDir = workingDir),
      error = function(e) stop(
        "Could not start an RStudio/Positron background job: ", conditionMessage(e),
        "\nUse `background = FALSE` for the classic gadget instead.", call. = FALSE))
  show_viewer <- show_viewer %||% function(u)
    rstudioapi::viewer(tryCatch(rstudioapi::translateLocalUrl(u, absolute = TRUE),
                                error = function(e) u))

  job_run(script_path, name = "Claude Code Chat", workingDir = spec$project)
  url <- sprintf("http://%s:%d", host, port)
  ready <- isTRUE(wait_ready(host, port))
  if (ready) show_viewer(url)
  invisible(list(port = port, url = url, script = script_path, spec_path = spec_path, ready = ready))
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
#' @param models Optional character vector of model names/aliases to offer in the Settings
#'   "Model" selector (e.g. `c("sonnet", "opus")`). A "Default" option is always prepended.
#'   Omit to use the built-in tiers (Default/Haiku/Sonnet/Opus). Switching is a live
#'   `set_model` (no reconnect).
#' @param options Optional [ClaudeAgentSDK::ClaudeAgentOptions] to fully override all defaults.
#' @param background Logical (default `FALSE`). If `TRUE`, run the chat as an RStudio
#'   **background job** (via [rstudioapi::jobRunScript()]) shown in the Viewer, so the R console
#'   stays free while you chat. IDE integration (editor context, open-file, Files pane, markers,
#'   save-before-edit) still works from the job via child-process `rstudioapi`. Requires a running
#'   RStudio session. `FALSE` keeps the classic blocking gadget.
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
                         models          = NULL,
                         options         = NULL,
                         background      = FALSE) {
  viewer          <- match.arg(viewer)
  permission_mode <- match.arg(permission_mode)
  project <- project %||% .addin_project()

  in_rstudio <- requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))

  # 后台模式(Plan 20)：Shiny 跑进 RStudio background job → R console 空出来;
  # IDE 集成经"子进程回连主会话"仍工作(已真机验证)。app 必须在 job 里构建,故只传参数。
  if (isTRUE(background)) {
    # 不卡 isAvailable()：Positron 等环境 isAvailable() 为 FALSE 但 jobRunScript 可用。
    # 只要 rstudioapi 在,就尝试;真不支持时由 jobRunScript 自身报清晰错误。
    if (!requireNamespace("rstudioapi", quietly = TRUE) ||
        !("jobRunScript" %in% getNamespaceExports("rstudioapi")))
      stop("`background = TRUE` needs the 'rstudioapi' package (RStudio or Positron).",
           call. = FALSE)
    spec <- list(project = project, options = options, permission_mode = permission_mode,
                 prewarm = prewarm, models = models)
    return(invisible(.run_claude_bg_job(spec)))
  }

  app <- .claude_chat_app(project, options = options,
                          permission_mode = permission_mode, prewarm = prewarm,
                          models = models)
  vw <- if (!in_rstudio) shiny::browserViewer()
        else switch(viewer,
                    pane    = shiny::paneViewer(minHeight = 600),
                    dialog  = shiny::dialogViewer("Claude Code", width = 1000, height = 800),
                    browser = shiny::browserViewer())
  invisible(.run_claude_gadget(app, vw))
}
