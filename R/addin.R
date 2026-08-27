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
    isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE)) &&
    ("filesPaneNavigate" %in% getNamespaceExports("rstudioapi"))
  if (!ok) return(invisible(FALSE))
  tryCatch({ rstudioapi::filesPaneNavigate(path); TRUE },
           error = function(e) FALSE)
}

# 延迟一拍再导航 Files 面板：修复"selectDirectory 模态返回后紧跟 filesPaneNavigate 被吞"
# (background job 里两个子进程 rstudioapi 调用相邻时,第二个不被主会话处理)。用 later 在
# 下一个事件循环 tick 执行,让模态的 RPC 上下文完全退出;收藏/手输路径(无模态)也照常工作。
.addin_files_pane_navigate_soon <- function(path, delay = 0.1) {
  if (requireNamespace("later", quietly = TRUE)) {
    force(path)
    later::later(function() .addin_files_pane_navigate(path), delay)
    invisible(TRUE)
  } else {
    .addin_files_pane_navigate(path)
  }
}

# 在用户的活 R 会话执行代码(代码块"Run in Console")。child_ok 环境 + sendToConsole 可用才执行;
# 从 background job 已验证可用。返回 TRUE/FALSE。
.addin_send_to_console <- function(code) {
  if (is.null(code) || !nzchar(code)) return(invisible(FALSE))
  ok <- requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE)) &&
    ("sendToConsole" %in% getNamespaceExports("rstudioapi"))
  if (!ok) return(invisible(FALSE))
  tryCatch({ rstudioapi::sendToConsole(code, execute = TRUE); TRUE },
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
      isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))) {
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
#' @param prewarm Passed to [assistantUIServer()] (default `TRUE`).
#'   Set `FALSE` to defer the Claude CLI connection until the first message.
#' @return A [shiny::shinyApp] object.
#' @keywords internal
#' @noRd
.claude_chat_app <- function(project, ctx = NULL, options = NULL,
                              permission_mode = "default", prewarm = TRUE,
                              models = NULL, console_url = NULL,
                              workspace = FALSE, workspace_projects = NULL,
                              lifecycle_nonce = NULL, lifecycle_mode = NULL) {
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
  # Plan 45/46:持久化 UI 偏好 —— 合并到 ~/.claude_addin/addin_settings.json(JSON,可手改)。
  # 首次运行若发现旧的 *_.rds 偏好,一次性迁移进 json 并删除旧文件(老用户无感)。
  .migrate_addin_settings()
  settings_state <- new.env(parent = emptyenv())
  settings_state$v <- .read_addin_settings()
  options$permission_mode <- settings_state$v$defaultPermissionMode  # handler 初始 + 新线程默认
  # session_map stored in user home to survive project switches
  session_map_path <- .claude_addin_path("session_map.rds")
  # 归档软隐藏存储（per-project，存于 home 以跨会话保留）
  archived_path <- .claude_addin_path("archived.rds")
  # Ordinary Chat keeps its historical single mutable cwd. Workspace uses a
  # thread-bound router so changing the selected project cannot reroute existing
  # or queued conversations.
  projects_path <- .claude_addin_path("projects.rds")
  dir_state <- new.env(parent = emptyenv())
  dir_state$cwd <- project
  workspace_router <- if (isTRUE(workspace)) {
    .new_workspace_project_router(
      c(workspace_projects, .read_saved_projects(projects_path)),
      initial = project
    )
  } else {
    NULL
  }
  cur_dir <- if (isTRUE(workspace)) workspace_router$current else function() dir_state$cwd
  project_for <- function(thread_id = NULL, project = NULL) {
    if (isTRUE(workspace)) {
      workspace_router$project_for(thread_id, project)
    } else {
      cur_dir()
    }
  }
  # Files 面板跟随偏好（持久化，默认 TRUE）：切目录时是否同步 RStudio Files 面板。
  follow_pref <- new.env(parent = emptyenv())
  follow_pref$on <- {
    p <- .claude_addin_path("follow_files.rds")
    v <- if (file.exists(p)) tryCatch(readRDS(p), error = function(e) TRUE) else TRUE
    if (is.logical(v) && length(v) == 1L && !is.na(v)) v else TRUE
  }
  # 角度 B(Plan 22):bg 模式下(console_url 存在且 SDK 支持进程内 MCP)把 run_r
  # 工具注入 options$mcp_servers,让 Claude 能在你的活 .GlobalEnv 执行 R(经角度 A
  # env-server,可见)。gadget 模式无 console_url → run_r_server 为 NULL,不注册。
  run_r_server <- if (!is.null(console_url)) .addin_run_r_server(console_url) else NULL
  if (!is.null(run_r_server)) {
    ms <- options$mcp_servers %||% list()
    ms[["r_session"]] <- run_r_server
    options$mcp_servers <- ms
  }
  handler <- make_claude_handler(
    options          = options,
    cwd_provider     = if (isTRUE(workspace)) project_for else cur_dir,
    models           = models,
    session_map_path = session_map_path
  )
  # 应用持久化的 run_r 开关(仅当 run_r 可用;首次连接前设置,reset_clients 无 client 时无副作用)。
  if (!is.null(run_r_server))
    tryCatch(attr(handler, "set_run_r_enabled")(settings_state$v$runREnabled), error = function(e) NULL)
  skills <- tryCatch(load_claude_skills(project_dir = cur_dir()), error = function(e) list())
  if (isTRUE(workspace)) {
    workspace_searchers <- new.env(parent = emptyenv())
    searcher_for <- function(project) {
      project <- .canonical_workspace_project(project)
      if (is.null(project)) return(NULL)
      searcher <- get0(project, envir = workspace_searchers, inherits = FALSE)
      if (is.null(searcher)) {
        searcher <- .make_addin_workspace_search_provider(project)
        assign(project, searcher, envir = workspace_searchers)
      }
      searcher
    }
    workspace_search <- function(query = "", kinds = c("file", "folder"),
                                 limit = 50L, thread_id = NULL, project = NULL) {
      target <- project_for(thread_id, project)
      searcher <- searcher_for(target)
      if (is.null(searcher)) return(list())
      searcher(query = query, kinds = kinds, limit = limit)
    }
    workspace_index_peek <- function(project) {
      searcher <- searcher_for(project)
      if (is.null(searcher)) return(NULL)
      peek <- attr(searcher, "peek_index")
      if (is.function(peek)) peek() else NULL
    }
  } else {
    workspace_search <- .make_addin_workspace_search_provider(cur_dir)
    workspace_index_peek <- attr(workspace_search, "peek_index")
  }

  ui <- .claude_chat_ui()
  # Inert per-generation markers let the main R session distinguish this exact
  # Shiny app from an unrelated process or an old app that reused the same port.
  if (is.character(lifecycle_nonce) && length(lifecycle_nonce) == 1L &&
      !is.na(lifecycle_nonce) && nzchar(lifecycle_nonce) &&
      is.character(lifecycle_mode) && length(lifecycle_mode) == 1L &&
      lifecycle_mode %in% c("chat", "workspace")) {
    ui <- htmltools::tagList(
      shiny::tags$head(
        shiny::tags$meta(name = "shinyassistant-bg-nonce", content = lifecycle_nonce),
        shiny::tags$meta(name = "shinyassistant-bg-mode", content = lifecycle_mode)
      ),
      ui
    )
  }
  server <- function(input, output, session) {
    # runGadget(stopOnCancel = TRUE) implements cancellation by deliberately
    # raising "User cancel". Shiny invokes options(shiny.error) before an outer
    # tryCatch can catch that error, which opens RStudio's debugger. Handle the
    # same input as a normal stopApp return instead.
    shiny::observeEvent(input$cancel, {
      .stop_claude_gadget_normally()
    }, ignoreInit = TRUE)

    # 启动时把 Files 面板同步到初始工作目录(受开关控制;延迟以确保会话就绪 + 避开 RPC 竞争)。
    if (isTRUE(follow_pref$on)) .addin_files_pane_navigate_soon(cur_dir(), delay = 0.8)

    # 工作目录选择器：RStudio 有原生目录弹窗；apply_working_dir 由下方定义（惰性引用 ctrl/push_sessions）。
    native_picker <- requireNamespace("rstudioapi", quietly = TRUE) &&
      isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))
    on_pick_wd <- function() {
      if (!native_picker) return(invisible(NULL))
      d <- tryCatch(rstudioapi::selectDirectory(caption = "Select working directory",
                                                path = cur_dir()),
                    error = function(e) NULL)
      if (!is.null(d) && nzchar(d)) apply_working_dir(d)
    }
    on_set_wd <- function(path) apply_working_dir(path)

    # 收藏夹（持久化 home）。保存当前目录 / 删除，改后回推列表。apply/ctrl 惰性引用。
    on_save_project <- function() {
      saved <- .add_saved_project(projects_path, cur_dir())
      # Workspace membership is session-local; Favorites are explicit and
      # persisted. Saving may ensure registry membership, but only `saved` is UI.
      if (isTRUE(workspace)) workspace_router$add(cur_dir())
      ctrl$send_projects(saved)
    }
    on_remove_project <- function(path) {
      saved <- .remove_saved_project(projects_path, path)
      # Unstarring must not remove the folder or its history from this Workspace.
      ctrl$send_projects(saved)
    }

    # The inner handler reconnects the current CLI thread after /reload-skills.
    # Only after that promise succeeds do we rescan direct local skills from the
    # current working directory and replace the local command snapshot.
    server_handler <- function(...) {
      args <- list(...)
      handler_params <- names(formals(handler))
      call_args <- if ("..." %in% handler_params) args
                   else args[names(args) %in% handler_params]
      result <- do.call(handler, call_args)
      if (!identical(args$message, "/reload-skills")) return(result)
      refresh_local <- function(value = NULL) {
        ctrl$send_commands(tryCatch(
          load_claude_skills(project_dir = project_for(args$thread_id, args$project)),
          error = function(e) list()
        ))
        value
      }
      if (inherits(result, "promise")) promises::then(result, refresh_local)
      else refresh_local(result)
    }
    for (attribute_name in names(attributes(handler)))
      attr(server_handler, attribute_name) <- attr(handler, attribute_name)

    # Internal addin feature: the generic assistant server only transports this
    # opaque initial config and never probes, starts, or controls copilot-api.
    copilot_plugin <- .new_copilot_addin_plugin(
      auto_start = settings_state$v$autoStartCopilotApi,
      persist_auto_start = function(value) {
        settings_state$v$autoStartCopilotApi <- isTRUE(value)
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
      }
    )
    ui_addons <- attr(server_handler, "ui_addons") %||% list()
    ui_addons$copilotService <- copilot_plugin$config()
    attr(server_handler, "ui_addons") <- ui_addons

    base_session_loader <- make_claude_session_loader(
      session_map_path = session_map_path
    )
    session_loader <- if (isTRUE(workspace)) {
      function(session_id, thread_id, send_thread, cursor = NULL, limit = 50L,
               project = NULL) {
        target <- project_for(thread_id, project)
        .call_compatible_callback(base_session_loader, list(
          session_id = session_id,
          thread_id = thread_id,
          send_thread = send_thread,
          cursor = cursor,
          limit = limit,
          project = target
        ))
      }
    } else {
      base_session_loader
    }

    ctrl <- assistantUIServer(
      "chat", handler = server_handler,
      show_thread_list = TRUE,
      persistence      = "server",
      latex            = TRUE,   # Claude Code 常输出数学公式 → 默认启用 KaTeX 渲染
      show_usage       = TRUE,   # 组合框下方环形显示上下文用量
      context_window   = 200000L, # Claude 默认上下文窗口
      usage_style      = "ring",
      workspace_mode    = isTRUE(workspace),
      working_dir      = cur_dir(),
      native_picker    = native_picker,
      on_pick_working_dir = on_pick_wd,
      on_set_working_dir  = on_set_wd,
      # `projects` is the Favorites protocol consumed by WorkingDirBar. The
      # Workspace registry remains private to workspace_router.
      projects          = .read_saved_projects(projects_path),
      on_save_project   = on_save_project,
      on_remove_project = on_remove_project,
      # Plan 45:Settings 偏好 —— 新会话默认权限模式 + 危险模式可见性。
      default_permission_mode = settings_state$v$defaultPermissionMode,
      on_set_default_permission_mode = function(m) {
        settings_state$v$defaultPermissionMode <- as.character(m)[[1L]]
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
        tryCatch(attr(handler, "set_default_permission_mode")(settings_state$v$defaultPermissionMode),
                 error = function(e) NULL)
      },
      mode_visibility = settings_state$v$modeVisibility,
      on_set_mode_visibility = function(v) {
        settings_state$v$modeVisibility <- list(showBypass = isTRUE(v$showBypass), showYolo = isTRUE(v$showYolo))
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
      },
      composer_density = settings_state$v$composerDensity,
      on_set_composer_density = function(d) {
        settings_state$v$composerDensity <- if (identical(as.character(d), "compact")) "compact" else "comfortable"
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
      },
      assistant_text_size = settings_state$v$assistantTextSize,
      on_set_assistant_text_size = function(value) {
        settings_state$v$assistantTextSize <- .normalize_assistant_text_size(value) %||% "medium"
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
      },
      run_r_enabled = if (!is.null(run_r_server)) settings_state$v$runREnabled else NULL,
      on_toggle_run_r = if (!is.null(run_r_server)) function(v) {
        settings_state$v$runREnabled <- isTRUE(v)
        tryCatch(.write_addin_settings(settings_state$v), error = function(e) NULL)
        tryCatch(attr(handler, "set_run_r_enabled")(settings_state$v$runREnabled), error = function(e) NULL)
      } else NULL,
      files_pane_follow = if (native_picker) follow_pref$on else NULL,
      on_toggle_files_pane_follow = function(v) {
        follow_pref$on <- isTRUE(v)
        tryCatch(saveRDS(follow_pref$on, .claude_addin_path("follow_files.rds")),
                 error = function(e) NULL)
        # 刚开启 → 立即把 Files 面板跟到当前目录（Bug2：开启动作本身也导航）。
        if (isTRUE(v)) .addin_files_pane_navigate_soon(cur_dir())
      },
      # 角度 B:自动批准 run_r 开关(仅当 run_r 已注册才暴露;初始关)。
      auto_run = if (!is.null(run_r_server)) FALSE else NULL,
      on_toggle_auto_run = if (!is.null(run_r_server)) function(v) {
        tryCatch(attr(handler, "set_autorun")(isTRUE(v)), error = function(e) NULL)
      } else NULL,
      on_session_load  = session_loader,
      commands         = skills,
      action_items     = .claude_action_items(),
      on_open_file     = if (native_picker) {
        function(path, line = NULL, thread_id = NULL, project = NULL) {
          target <- project_for(thread_id, project)
          peek <- if (isTRUE(workspace)) {
            function() workspace_index_peek(target)
          } else {
            workspace_index_peek
          }
          .addin_open_file(path, line, target, peek)
        }
      } else NULL,
      on_run_in_console = if (requireNamespace("rstudioapi", quietly = TRUE) &&
                              isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE),
                                              error = function(e) FALSE))) {
        if (!is.null(console_url))
          function(code) .addin_run_r_remote(console_url, code)          # 主会话 .GlobalEnv + 捕获回传
        else
          function(code) { .addin_send_to_console(code); list(ok = TRUE, output = "", error = NULL) }
      } else NULL,
      on_edits         = function(edits, thread_id = NULL, project = NULL) {
        .addin_show_edit_markers(edits, project_for(thread_id, project))
      },
      on_rename        = function(thread_id, title, project = NULL)
        .claude_rename_session(
          thread_id, title, session_map_path, project_for(thread_id, project)
        ),
      on_archive_session = function(session_id, archived, project = NULL) {
        # 仅服务端持久化软隐藏；前端已本地乐观更新（移入/移出归档区）。
        # 不再重推会话列表——重推会把"当前对话已生成的 server session"与其客户端新线程
        # 双显（同标题两条）。重开时初始推送（带 archived 标记）才是权威来源。
        .toggle_archived_id(
          archived_path, project_for(session_id, project), session_id, archived
        )
      },
      on_delete_session = function(session_id, project = NULL) {
        # 删前断开该 session 的 client（避免 CLI 写回）；真删失败不再静默——重推让它重现。
        .claude_delete_session(
          session_id, project = project_for(session_id, project), handler = handler,
          archived_path = archived_path, session_map_path = session_map_path,
          on_reappear = function() tryCatch(push_sessions(), error = function(e) NULL)
        )
      },
      ide_context_provider = function(thread_id = NULL, project = NULL) {
        # 提交前保存活动文档（有路径的；untitled 跳过）→ Claude 编辑基于最新、且不丢未保存改动。
        .addin_save_dirty_docs()
        .addin_editor_context(project_for(thread_id, project))
      },
      workspace_search_provider = workspace_search,
      warming_label    = "Starting Claude Code\u2026",
      prewarm          = prewarm,
      max_concurrent_runs = if (isTRUE(workspace)) 4L else 2L
    )

    # Binding is session-local. The plugin starts its independent service only
    # after the frontend addon channel reports that its status handler is ready.
    copilot_plugin$bind(session, "chat_input")

    # 统一的会话推送：带 archived 标记（服务端权威）。闭包惰性引用 ctrl（用户点击时
    # 才运行，ctrl 已赋值）。按当前工作目录 cur_dir() 分桶。
    push_sessions <- function() {
      payload <- if (isTRUE(workspace)) {
        snapshot <- .workspace_session_snapshot(
          workspace_router$projects(),
          archived_path = archived_path
        )
        if (!isTRUE(workspace_router$order_initialized())) {
          workspace_router$reorder(.workspace_project_activity_order(
            workspace_router$projects(),
            snapshot,
            current = cur_dir()
          ))
        }
        project_order <- workspace_router$projects()
        if (length(snapshot)) {
          snapshot_projects <- vapply(snapshot, `[[`, character(1), "project")
          snapshot <- snapshot[order(match(snapshot_projects, project_order))]
        }
        for (item in snapshot) {
          workspace_router$project_for(item$id, item$project)
        }
        list(sessions = snapshot, projectOrder = as.list(project_order))
      } else {
        sessions <- .call_compatible_callback(list_claude_sessions, list(
          directory = cur_dir(),
          archived_ids = .read_archived_ids(archived_path, cur_dir())
        ))
        list(sessions = sessions)
      }
      ctrl$send_sessions(payload)
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
      # 用 _soon 延迟一拍,避开"selectDirectory 模态后紧跟调用被吞"。
      if (isTRUE(follow_pref$on)) .addin_files_pane_navigate_soon(nd)
      if (isTRUE(workspace)) {
        if (identical(nd, cur_dir())) return(invisible(nd))
        workspace_router$select(nd)
        tryCatch(
          ctrl$send_commands(load_claude_skills(project_dir = nd)),
          error = function(e) NULL
        )
        recent <- add_recent(nd)
        ctrl$send_working_dir(nd, as.list(recent))
        ctrl$send_projects(.read_saved_projects(projects_path))
        push_sessions()
        return(invisible(nd))
      }
      if (identical(nd, dir_state$cwd)) return(invisible(nd))   # cwd 未变 → 跳过重连/收藏/推送
      dir_state$cwd <- nd
      tryCatch(attr(handler, "reset_clients")(), error = function(e) NULL)
      # 切目录后重载新项目的 skills/commands 并热更新 slash 菜单(之前只在启动读一次 →
      # 切过去看不到新项目 .claude 的 skills)。
      tryCatch(
        ctrl$send_commands(load_claude_skills(project_dir = nd)),
        error = function(e) NULL
      )
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
  # 删前抓该 session 的 tool_use id（transcript 还在）；Workspace 必须在对应项目目录查找。
  tool_ids <- tryCatch(
    .session_tool_use_ids(session_id, directory = project),
    error = function(e) character(0)
  )
  ok <- tryCatch({ .delete_claude_session(session_id, directory = project); TRUE },
                 error = function(e) {
                   warning("[CLAUDE] delete_session failed: ", conditionMessage(e), call. = FALSE)
                   FALSE
                 })
  if (isTRUE(ok)) {
    .toggle_archived_id(archived_path, project, session_id, FALSE)
    tryCatch(.remove_claude_session_map(session_map_path, session_id), error = function(e) NULL)
    tryCatch(.prune_tool_decisions(.claude_decisions_path(session_map_path), tool_ids),
             error = function(e) NULL)
    tryCatch(.prune_tool_metadata(.claude_tool_metadata_path(session_map_path), tool_ids),
             error = function(e) NULL)
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
      !isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))) return(invisible(NULL))
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

# ── Background-job launcher (Plan 20 / Plan 93 lifecycle) ──────────────────
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

# Legacy TCP waiter remains available for callers/tests that explicitly need it.
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

.claude_bg_registry <- new.env(parent = emptyenv())

.claude_bg_mode <- function(spec) if (isTRUE(spec$workspace)) "workspace" else "chat"

.claude_bg_registry_key <- function(spec) {
  project <- .canonical_workspace_project(spec$project) %||% as.character(spec$project %||% "")
  paste(.claude_bg_mode(spec), project, sep = "::")
}

.claude_bg_request_snapshot <- function(spec) {
  out <- spec
  out$project <- .canonical_workspace_project(spec$project) %||% as.character(spec$project %||% "")
  out$workspace <- isTRUE(spec$workspace)
  out$workspace_projects <- if (out$workspace) {
    .canonical_workspace_projects(spec$workspace_projects)
  } else {
    NULL
  }
  for (name in c(
    "console_url", "job_name", ".claude_bg_nonce", ".claude_bg_mode",
    ".claude_bg_generation", ".claude_bg_log_path"
  )) out[[name]] <- NULL
  out
}

.claude_bg_request_fingerprint <- function(spec) {
  serialize(.claude_bg_request_snapshot(spec), NULL, version = 2L)
}

.claude_bg_nonce <- function() {
  alphabet <- c(letters, LETTERS, 0:9)
  random <- paste0(sample(alphabet, 24L, replace = TRUE), collapse = "")
  paste(Sys.getpid(), format(Sys.time(), "%Y%m%d%H%M%OS6", tz = "UTC"), random,
        sep = "-")
}

.claude_bg_log_path <- function(spec, port, nonce, generation,
                                home = Sys.getenv("HOME", unset = "~")) {
  directory <- .claude_addin_path("logs", home = home)
  suppressWarnings(dir.create(directory, recursive = TRUE, showWarnings = FALSE))
  stamp <- format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC")
  file.path(directory, sprintf(
    "%s-%s-g%d-p%d.log", .claude_bg_mode(spec), stamp,
    as.integer(generation), as.integer(port)
  ))
}

.claude_bg_log_value <- function(value) {
  if (is.null(value) || !length(value)) return("")
  value <- as.character(value[[1L]])
  if (is.na(value) || !nzchar(value)) return("")
  gsub("[^A-Za-z0-9_.:+-]", "_", value)
}

# Explicit allowlisted lifecycle logger. Never redirect global output and never
# record specs, environment values, condition text, prompts, or responses.
.claude_bg_log_event <- function(path, event, mode = NULL, generation = NULL,
                                 nonce = NULL, port = NULL, condition = NULL) {
  tryCatch({
    if (is.null(path) || !length(path) || is.na(path[[1L]]) || !nzchar(path[[1L]]))
      return(invisible(NULL))
    path <- as.character(path[[1L]])
    suppressWarnings(dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE))
    fields <- list(
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"),
      event = event,
      mode = mode,
      generation = generation,
      nonce = nonce,
      port = port,
      package_version = tryCatch(
        as.character(utils::packageVersion("shinyAssistantUI")),
        error = function(e) "unknown"
      ),
      condition_class = if (!is.null(condition)) class(condition)[[1L]] else NULL
    )
    values <- vapply(fields, .claude_bg_log_value, character(1), USE.NAMES = FALSE)
    keep <- !vapply(fields, is.null, logical(1))
    line <- paste0(names(fields)[keep], "=", values[keep], collapse = " ")
    cat(line, "\n", file = path, append = TRUE, sep = "")
  }, warning = function(w) NULL, error = function(e) NULL)
  invisible(NULL)
}

.claude_bg_response_matches <- function(lines, nonce, mode) {
  if (!is.character(lines) || !length(lines) ||
      !is.character(nonce) || length(nonce) != 1L || is.na(nonce) || !nzchar(nonce) ||
      !is.character(mode) || length(mode) != 1L || !mode %in% c("chat", "workspace")) {
    return(FALSE)
  }
  status <- grepl("^HTTP/1\\.[01] 2[0-9][0-9]( |$)", lines[[1L]], perl = TRUE)
  text <- paste(lines, collapse = "\n")
  nonce_marker <- paste0(
    'name="shinyassistant-bg-nonce" content="', nonce, '"'
  )
  mode_marker <- paste0(
    'name="shinyassistant-bg-mode" content="', mode, '"'
  )
  isTRUE(status) && grepl(nonce_marker, text, fixed = TRUE) &&
    grepl(mode_marker, text, fixed = TRUE)
}

.claude_bg_probe_instance <- function(host, port, nonce, mode, timeout = 1) {
  con <- tryCatch(
    socketConnection(
      host = host, port = as.integer(port), server = FALSE, blocking = TRUE,
      open = "r+", timeout = timeout, encoding = "UTF-8"
    ),
    warning = function(w) NULL, error = function(e) NULL
  )
  if (is.null(con)) return(FALSE)
  on.exit(try(close(con), silent = TRUE), add = TRUE)
  lines <- tryCatch({
    writeLines(c(
      "GET / HTTP/1.0",
      sprintf("Host: %s:%d", host, as.integer(port)),
      "Connection: close", ""
    ), con = con, sep = "\r\n", useBytes = TRUE)
    readLines(con, n = 4096L, warn = FALSE, encoding = "UTF-8")
  }, warning = function(w) character(), error = function(e) character())
  .claude_bg_response_matches(lines, nonce, mode)
}

.claude_bg_default_job_state <- function(job_id) {
  if (is.null(job_id) || !length(job_id) || is.na(job_id[[1L]]) ||
      !nzchar(as.character(job_id[[1L]])) ||
      !requireNamespace("rstudioapi", quietly = TRUE)) return(NA_character_)
  tryCatch(rstudioapi::jobGetState(as.character(job_id[[1L]])),
           error = function(e) NA_character_)
}

.claude_bg_safe_job_state <- function(job_id, job_state) {
  value <- tryCatch(
    .call_compatible_callback(job_state, list(job_id = job_id)),
    warning = function(w) NA_character_, error = function(e) NA_character_
  )
  if (is.list(value) && !is.null(value$state)) value <- value$state
  if (is.null(value) || !length(value)) return(NA_character_)
  value <- as.character(value[[1L]])
  if (is.na(value) || !value %in% c("idle", "running", "succeeded", "cancelled", "failed"))
    NA_character_
  else value
}

.claude_bg_active_state <- function(state) !is.na(state) && state %in% c("idle", "running")
.claude_bg_terminal_state <- function(state) !is.na(state) && state %in% c("succeeded", "cancelled", "failed")

.claude_bg_valid_record <- function(record) {
  is.list(record) && is.raw(record$fingerprint) &&
    is.character(record$mode) && length(record$mode) == 1L &&
    is.character(record$project) && length(record$project) == 1L &&
    is.numeric(record$generation) && length(record$generation) == 1L &&
    is.character(record$nonce) && length(record$nonce) == 1L && nzchar(record$nonce) &&
    is.numeric(record$port) && length(record$port) == 1L &&
    is.character(record$url) && length(record$url) == 1L &&
    is.character(record$status) && length(record$status) == 1L
}

.claude_bg_get_record <- function(registry, key) {
  record <- get0(key, envir = registry, inherits = FALSE)
  if (.claude_bg_valid_record(record)) record else NULL
}

.claude_bg_record_current <- function(registry, key, generation, identity = NULL) {
  current <- .claude_bg_get_record(registry, key)
  if (is.null(current) ||
      !identical(as.integer(current$generation), as.integer(generation))) return(FALSE)
  if (is.null(identity)) return(TRUE)
  identical(current$transaction_id %||% current$nonce, identity)
}

.claude_bg_result <- function(record, ready, reused = FALSE, superseded = FALSE,
                              in_progress = FALSE) {
  invisible(list(
    port = as.integer(record$port), url = record$url,
    script = record$script, spec_path = record$spec_path,
    ready = isTRUE(ready), job_id = record$job_id,
    nonce = record$nonce, mode = record$mode,
    generation = as.integer(record$generation),
    log_path = record$log_path, reused = isTRUE(reused),
    superseded = isTRUE(superseded), in_progress = isTRUE(in_progress),
    state = record$job_state
  ))
}

.claude_bg_wait_result <- function(wait_ready, record, instance_probe, job_state) {
  value <- tryCatch(
    .call_compatible_callback(wait_ready, list(
      host = record$host, port = record$port, nonce = record$nonce,
      mode = record$mode, job_id = record$job_id,
      instance_probe = instance_probe, job_state = job_state
    )),
    error = function(e) e
  )
  if (inherits(value, "error")) {
    return(list(ready = FALSE, state = .claude_bg_safe_job_state(record$job_id, job_state),
                condition = value))
  }
  if (is.list(value) && !is.null(value$ready)) {
    value$ready <- isTRUE(value$ready)
    value$state <- value$state %||% .claude_bg_safe_job_state(record$job_id, job_state)
    return(value)
  }
  list(ready = isTRUE(value), state = .claude_bg_safe_job_state(record$job_id, job_state),
       condition = NULL)
}

.claude_wait_for_instance <- function(host, port, nonce, mode, job_id = NULL,
                                      instance_probe = .claude_bg_probe_instance,
                                      job_state = .claude_bg_default_job_state,
                                      timeout = 30, interval = 0.25) {
  deadline <- Sys.time() + timeout
  repeat {
    state <- .claude_bg_safe_job_state(job_id, job_state)
    if (.claude_bg_terminal_state(state))
      return(list(ready = FALSE, state = state, reason = "terminal"))
    healthy <- isTRUE(tryCatch(
      .call_compatible_callback(instance_probe, list(
        host = host, port = port, nonce = nonce, mode = mode
      )),
      warning = function(w) FALSE, error = function(e) FALSE
    ))
    if (healthy) return(list(ready = TRUE, state = state, reason = "ready"))
    if (Sys.time() >= deadline)
      return(list(ready = FALSE, state = state, reason = "timeout"))
    Sys.sleep(interval)
  }
}

.claude_bg_startup_error <- function(record, state = NA_character_, existing = FALSE) {
  label <- if (identical(record$mode, "workspace")) "Claude Workspace" else "Claude Code Chat"
  prefix <- if (isTRUE(existing)) paste("The existing", label) else label
  state_text <- if (is.na(state)) "unknown" else state
  id_text <- if (is.null(record$job_id) || !length(record$job_id)) "unknown" else
    as.character(record$job_id[[1L]])
  paste0(
    prefix, " background job did not become ready at ", record$url,
    "; Job ID: ", id_text, "; state: ", state_text,
    "; lifecycle log: ", record$log_path,
    ". Inspect the existing RStudio Jobs entry, resolve the failure, then run the same existing Addin again."
  )
}

# Generate a background script with explicit identity/diagnostic parameters.
.claude_bg_launch_script <- function(spec_path, port, host, libpaths,
                                     log_path = NULL, nonce = NULL, mode = NULL) {
  args <- c(
    deparse(spec_path),
    sprintf("port = %dL", as.integer(port)),
    sprintf("host = %s", deparse(host))
  )
  if (!is.null(log_path)) args <- c(args, sprintf("log_path = %s", deparse(log_path)))
  if (!is.null(nonce)) args <- c(args, sprintf("nonce = %s", deparse(nonce)))
  if (!is.null(mode)) args <- c(args, sprintf("mode = %s", deparse(mode)))
  c(
    sprintf(".libPaths(%s)", paste(deparse(as.character(libpaths)), collapse = "")),
    "library(shinyAssistantUI)",
    sprintf("shinyAssistantUI:::.claude_run_in_job(%s)", paste(args, collapse = ", "))
  )
}

# Job process: read immutable launch parameters, construct the shared app core,
# and append only allowlisted lifecycle events to the dedicated log.
.claude_run_in_job <- function(spec_path, port, host = "127.0.0.1",
                               log_path = NULL, nonce = NULL, mode = NULL) {
  outcome <- "stopped"
  .claude_bg_log_event(log_path, "starting", mode = mode, nonce = nonce, port = port)
  on.exit(.claude_bg_log_event(
    log_path, outcome, mode = mode, nonce = nonce, port = port
  ), add = TRUE)
  tryCatch({
    spec <- readRDS(spec_path)
    nonce <- nonce %||% spec$.claude_bg_nonce
    mode <- mode %||% spec$.claude_bg_mode %||% .claude_bg_mode(spec)
    app <- .call_compatible_callback(.claude_chat_app, list(
      project = spec$project,
      options = spec$options,
      permission_mode = spec$permission_mode %||% "default",
      prewarm = isTRUE(spec$prewarm),
      models = spec$models,
      console_url = spec$console_url,
      workspace = isTRUE(spec$workspace),
      workspace_projects = spec$workspace_projects,
      lifecycle_nonce = nonce,
      lifecycle_mode = mode
    ))
    .claude_bg_log_event(log_path, "app_built", mode = mode, nonce = nonce, port = port)
    result <- shiny::runApp(app, port = as.integer(port), host = host, launch.browser = FALSE)
    outcome <- "completed"
    result
  }, error = function(e) {
    outcome <<- "failed"
    .claude_bg_log_event(log_path, "failed", mode = mode, nonce = nonce,
                         port = port, condition = e)
    stop(e)
  })
}

# Main-session shared lifecycle manager for both Chat and Workspace.
.run_claude_bg_job <- function(
    spec, host = "127.0.0.1", port = NULL, libpaths = .libPaths(),
    job_run = NULL, show_viewer = NULL,
    wait_ready = .claude_wait_for_instance,
    registry = .claude_bg_registry,
    port_factory = .claude_random_port,
    nonce_factory = .claude_bg_nonce,
    log_path = NULL,
    log_path_factory = .claude_bg_log_path,
    instance_probe = .claude_bg_probe_instance,
    job_state = .claude_bg_default_job_state) {
  stopifnot(is.environment(registry))
  show_viewer <- show_viewer %||% function(u) {
    rstudioapi::viewer(tryCatch(
      rstudioapi::translateLocalUrl(u, absolute = TRUE), error = function(e) u
    ))
  }
  request <- spec
  request$project <- .canonical_workspace_project(spec$project) %||% as.character(spec$project %||% "")
  request$workspace <- isTRUE(spec$workspace)
  if (request$workspace)
    request$workspace_projects <- .canonical_workspace_projects(spec$workspace_projects)
  key <- .claude_bg_registry_key(request)
  fingerprint <- .claude_bg_request_fingerprint(request)
  existing <- .claude_bg_get_record(registry, key)
  # A synchronous re-entrant invocation must observe the transaction reservation
  # instead of allocating another generation while the first submission callback
  # is still on the stack.
  if (!is.null(existing) && identical(existing$status, "submitting")) {
    return(.claude_bg_result(
      existing, ready = FALSE, reused = TRUE, in_progress = TRUE
    ))
  }
  console_matches <- !is.null(existing) && identical(
    existing$console_url %||% NULL, request$console_url %||% NULL
  )
  matches <- !is.null(existing) && console_matches &&
    identical(existing$fingerprint, fingerprint)

  probe_record <- function(record) isTRUE(tryCatch(
    .call_compatible_callback(instance_probe, list(
      host = record$host, port = record$port,
      nonce = record$nonce, mode = record$mode
    )), warning = function(w) FALSE, error = function(e) FALSE
  ))
  open_viewer <- function(url) {
    .call_compatible_callback(show_viewer, list(u = url))
    invisible(NULL)
  }

  if (matches) {
    state <- .claude_bg_safe_job_state(existing$job_id, job_state)
    healthy <- probe_record(existing)
    # Both callbacks above are injectable and can re-enter this manager. Never
    # publish the captured record if a newer transaction replaced it meanwhile.
    if (!.claude_bg_record_current(
      registry, key, existing$generation, existing$transaction_id %||% existing$nonce
    )) {
      return(.claude_bg_result(
        existing, ready = FALSE, reused = TRUE, superseded = TRUE
      ))
    }
    if (healthy && !.claude_bg_terminal_state(state)) {
      existing$status <- "ready"
      existing$job_state <- state
      existing$last_checked_at <- Sys.time()
      assign(key, existing, envir = registry)
      open_viewer(existing$url)
      return(.claude_bg_result(existing, ready = TRUE, reused = TRUE))
    }
    should_wait <- !healthy && (
      .claude_bg_active_state(state) ||
        (is.na(state) && existing$status %in% c("starting", "timeout"))
    )
    if (should_wait) {
      waited <- .claude_bg_wait_result(wait_ready, existing, instance_probe, job_state)
      if (!.claude_bg_record_current(
        registry, key, existing$generation, existing$transaction_id %||% existing$nonce
      ))
        return(.claude_bg_result(existing, ready = FALSE, reused = TRUE, superseded = TRUE))
      existing$job_state <- waited$state
      existing$last_checked_at <- Sys.time()
      if (isTRUE(waited$ready)) {
        existing$status <- "ready"
        assign(key, existing, envir = registry)
        open_viewer(existing$url)
        return(.claude_bg_result(existing, ready = TRUE, reused = TRUE))
      }
      existing$status <- "timeout"
      assign(key, existing, envir = registry)
      .claude_bg_log_event(existing$log_path, "timeout", mode = existing$mode,
                           generation = existing$generation, nonce = existing$nonce,
                           port = existing$port, condition = waited$condition)
      stop(.claude_bg_startup_error(existing, waited$state, existing = TRUE), call. = FALSE)
    }
  }

  previous <- existing
  generation <- if (!is.null(existing)) as.integer(existing$generation) + 1L else 1L
  mode <- .claude_bg_mode(request)
  transaction_id <- paste0("txn-", .claude_bg_nonce())
  # Publish a callback-free reservation before invoking any injectable allocator,
  # logger factory, Job submitter, or state provider. It is rolled back only when
  # this exact transaction still owns the key.
  record <- list(
    fingerprint = fingerprint, mode = mode, project = request$project,
    workspace_projects = request$workspace_projects,
    console_url = request$console_url %||% NULL,
    generation = generation, transaction_id = transaction_id,
    nonce = transaction_id, job_id = NULL,
    host = host, port = 0L, url = "",
    script = NULL, spec_path = NULL, log_path = NULL,
    status = "submitting", job_state = NA_character_,
    created_at = Sys.time(), last_checked_at = Sys.time()
  )
  assign(key, record, envir = registry)
  rollback <- function() {
    if (!.claude_bg_record_current(registry, key, generation, transaction_id))
      return(invisible(FALSE))
    if (!is.null(previous)) assign(key, previous, envir = registry)
    else if (exists(key, envir = registry, inherits = FALSE))
      rm(list = key, envir = registry)
    invisible(TRUE)
  }

  prepared <- tryCatch({
    port_value <- as.integer(port %||% .call_compatible_callback(port_factory, list()))
    nonce_value <- as.character(.call_compatible_callback(nonce_factory, list()))[[1L]]
    url_value <- sprintf("http://%s:%d", host, port_value)
    log_value <- log_path
    if (is.null(log_value)) {
      log_value <- .call_compatible_callback(log_path_factory, list(
        spec = request, port = port_value, nonce = nonce_value,
        generation = generation
      ))
    }
    log_value <- as.character(log_value)[[1L]]
    spec_value <- tempfile("claude-addin-spec-", fileext = ".rds")
    script_value <- tempfile("claude-addin-job-", fileext = ".R")
    materialized <- request
    materialized$.claude_bg_nonce <- nonce_value
    materialized$.claude_bg_mode <- mode
    materialized$.claude_bg_generation <- generation
    materialized$.claude_bg_log_path <- log_value
    saveRDS(materialized, spec_value)
    writeLines(.claude_bg_launch_script(
      spec_value, port_value, host, libpaths,
      log_path = log_value, nonce = nonce_value, mode = mode
    ), script_value)
    list(
      port = port_value, nonce = nonce_value, url = url_value,
      log_path = log_value, spec_path = spec_value, script = script_value
    )
  }, error = function(e) {
    rollback()
    stop(e)
  })
  if (!.claude_bg_record_current(registry, key, generation, transaction_id)) {
    unlink(c(prepared$spec_path, prepared$script))
    return(.claude_bg_result(
      record, ready = FALSE, reused = FALSE, superseded = TRUE
    ))
  }
  record$port <- prepared$port
  record$nonce <- prepared$nonce
  record$url <- prepared$url
  record$log_path <- prepared$log_path
  record$spec_path <- prepared$spec_path
  record$script <- prepared$script
  assign(key, record, envir = registry)

  job_run <- job_run %||% function(path, name, workingDir) {
    tryCatch(
      rstudioapi::jobRunScript(path, name = name, workingDir = workingDir),
      error = function(e) stop(
        "Could not start an RStudio/Positron background job: ", conditionMessage(e),
        "\nUse `background = FALSE` for the classic gadget instead.", call. = FALSE
      )
    )
  }
  job_name <- as.character(request$job_name %||% if (mode == "workspace") {
    "Claude Workspace"
  } else {
    "Claude Code Chat"
  })[[1L]]

  .claude_bg_log_event(record$log_path, "submitting", mode = mode,
                       generation = generation, nonce = record$nonce,
                       port = record$port)
  job_id <- tryCatch(
    .call_compatible_callback(job_run, list(
      path = record$script, name = job_name, workingDir = request$project
    )),
    error = function(e) {
      .claude_bg_log_event(record$log_path, "submission_failed", mode = mode,
                           generation = generation, nonce = record$nonce,
                           port = record$port, condition = e)
      rollback()
      unlink(c(record$spec_path, record$script))
      stop(e)
    }
  )
  if (!.claude_bg_record_current(registry, key, generation, transaction_id)) {
    return(.claude_bg_result(
      record, ready = FALSE, reused = FALSE, superseded = TRUE
    ))
  }
  if (!is.null(job_id) && length(job_id)) {
    job_id <- as.character(job_id[[1L]])
    if (is.na(job_id) || !nzchar(job_id)) job_id <- NULL
  } else job_id <- NULL
  record$job_id <- job_id
  record$status <- "starting"
  record$job_state <- .claude_bg_safe_job_state(job_id, job_state)
  record$last_checked_at <- Sys.time()
  if (!.claude_bg_record_current(registry, key, generation, transaction_id)) {
    return(.claude_bg_result(
      record, ready = FALSE, reused = FALSE, superseded = TRUE
    ))
  }
  assign(key, record, envir = registry)
  .claude_bg_log_event(record$log_path, "starting", mode = mode,
                       generation = generation, nonce = record$nonce,
                       port = record$port)

  waited <- .claude_bg_wait_result(wait_ready, record, instance_probe, job_state)
  if (!.claude_bg_record_current(registry, key, generation, transaction_id))
    return(.claude_bg_result(record, ready = FALSE, reused = FALSE, superseded = TRUE))
  record$job_state <- waited$state
  record$last_checked_at <- Sys.time()
  if (isTRUE(waited$ready)) {
    record$status <- "ready"
    assign(key, record, envir = registry)
    .claude_bg_log_event(record$log_path, "ready", mode = mode,
                         generation = generation, nonce = record$nonce,
                         port = record$port)
    open_viewer(record$url)
    return(.claude_bg_result(record, ready = TRUE, reused = FALSE))
  }

  record$status <- "timeout"
  assign(key, record, envir = registry)
  .claude_bg_log_event(record$log_path, "timeout", mode = mode,
                       generation = generation, nonce = record$nonce,
                       port = record$port, condition = waited$condition)
  stop(.claude_bg_startup_error(record, waited$state, existing = FALSE), call. = FALSE)
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
#' @param prewarm Logical (default `TRUE`). Pre-connect the Claude CLI after the
#'   interface mounts so the first message does not pay the cold-start cost (see
#'   [assistantUIServer()]). A visible warming indicator remains until initialization
#'   completes. Set `FALSE` to defer connecting until the first message.
#' @param models Optional character vector of model names/aliases to offer in the Settings
#'   "Model" selector (e.g. `c("sonnet", "opus")`). A "Default" option is always prepended.
#'   Omit to use the built-in tiers (Default/Haiku/Sonnet/Opus). Switching is a live
#'   `set_model` (no reconnect).
#' @param options Optional [ClaudeAgentSDK::ClaudeAgentOptions] to fully override all defaults.
#' @param background Logical (default `TRUE`). Run the chat as an RStudio/Positron
#'   **background job** (via [rstudioapi::jobRunScript()]) shown in the Viewer, so the R console
#'   stays free while you chat. IDE integration (editor context, open-file, Files pane, markers,
#'   save-before-edit) still works from the job via child-process `rstudioapi`. Falls back to the
#'   classic blocking gadget when background jobs aren't available (e.g. plain R / browser). Set
#'   `FALSE` to force the classic gadget.
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
                         prewarm         = TRUE,
                         models          = NULL,
                         options         = NULL,
                         background      = TRUE) {
  .launch_claude_addin(
    project = project,
    viewer = match.arg(viewer),
    permission_mode = match.arg(permission_mode),
    prewarm = prewarm,
    models = models,
    options = options,
    background = background
  )
}

#' Open a multi-project Claude Workspace inside RStudio
#'
#' Launches the same Claude Code chat core as [claude_addin()] in workspace mode.
#' Sessions are grouped and routed by project, and up to four different threads
#' may run concurrently. Existing saved projects are included automatically.
#'
#' @inheritParams claude_addin
#' @param projects Optional character vector of additional project directories.
#'   Paths are canonicalized and deduplicated; missing paths remain registered
#'   but are not queried until they become available.
#' @return Invisibly, the result of [shiny::runGadget()] or the background-job
#'   launcher metadata.
#' @export
#' @examples
#' \dontrun{
#'   claude_workspace_addin()
#'   claude_workspace_addin(projects = c("~/project-a", "~/project-b"))
#' }
claude_workspace_addin <- function(
    project = NULL,
    projects = NULL,
    viewer = c("pane", "dialog", "browser"),
    permission_mode = c("default", "plan", "acceptEdits", "bypassPermissions"),
    prewarm = TRUE,
    models = NULL,
    options = NULL,
    background = TRUE) {
  .launch_claude_addin(
    project = project,
    viewer = match.arg(viewer),
    permission_mode = match.arg(permission_mode),
    prewarm = prewarm,
    models = models,
    options = options,
    background = background,
    workspace = TRUE,
    projects = projects
  )
}

.launch_claude_addin <- function(project, viewer, permission_mode, prewarm,
                                 models, options, background, workspace = FALSE,
                                 projects = NULL) {
  project <- project %||% .addin_project()
  in_rstudio <- requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))

  can_background <- isTRUE(background) && in_rstudio &&
    ("jobRunScript" %in% getNamespaceExports("rstudioapi"))
  if (can_background) {
    # One main-session run_r endpoint is shared by every Chat/Workspace Job.
    # Ensuring it is idempotent prevents a healthy reopen from invalidating the
    # socket still used by an existing background app.
    console_url <- .addin_ensure_r_console_server(envir = globalenv())
    spec <- list(
      project = project,
      options = options,
      permission_mode = permission_mode,
      prewarm = prewarm,
      models = models,
      console_url = console_url,
      workspace = isTRUE(workspace),
      workspace_projects = projects,
      job_name = if (isTRUE(workspace)) "Claude Workspace" else "Claude Code Chat"
    )
    return(invisible(.run_claude_bg_job(spec)))
  }

  app <- .claude_chat_app(
    project,
    options = options,
    permission_mode = permission_mode,
    prewarm = prewarm,
    models = models,
    workspace = workspace,
    workspace_projects = projects
  )
  viewer_function <- if (!in_rstudio) {
    shiny::browserViewer()
  } else {
    switch(
      viewer,
      pane = shiny::paneViewer(minHeight = 600),
      dialog = shiny::dialogViewer(
        if (isTRUE(workspace)) "Claude Workspace" else "Claude Code",
        width = 1000,
        height = 800
      ),
      browser = shiny::browserViewer()
    )
  }
  invisible(.run_claude_gadget(app, viewer_function))
}
