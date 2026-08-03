#' Assistant UI Server Module
#'
#' Handles the server-side logic for an [assistantUIOutput()] widget: receives
#' user messages, calls a backend handler, and streams responses back to the UI.
#'
#' @param id The module ID matching the `outputId` passed to [assistantUIOutput()].
#' @param handler A function with signature
#'   `function(message, thread_id, on_chunk, on_done, on_error,
#'              on_tool_call, on_tool_result, is_reload)` where:
#'   * `message` — character string of the user's message.
#'   * `thread_id` — character string identifying the current thread (for
#'     multi-turn conversation routing).
#'   * `on_chunk(text)` — call repeatedly to stream response tokens.
#'   * `on_done()` — call once when the response is complete.
#'   * `on_error(msg)` — call to surface an error in the UI.
#'   * `on_tool_call(tool_call_id, tool_name, args, annotations)` — show a
#'     tool call card. `args` should be a named list. `annotations` is an
#'     optional named list controlling card appearance and result rendering.
#'     Recognized keys:
#'     * `icon` — lucide icon name (`"search"`, `"database"`, `"code"`, …)
#'     * `title` — display name shown in the card header
#'     * `requiresApproval` — `TRUE` to show Approve/Deny buttons
#'     * `resultType` — how to render the result from `on_tool_result()`:
#'       `"auto"` (default, JSON/text in `<pre>`), `"markdown"`,
#'       `"table"`, `"code"`, `"image"`, `"file"`, `"html"`
#'     * `resultLang` — language for `resultType = "code"` (e.g. `"r"`,
#'       `"python"`, `"sql"`; default `"text"`)
#'     * `resultFilename` — filename for `resultType = "file"` download
#'       button (e.g. `"results.csv"`; default `"download"`)
#'   * `on_tool_result(tool_call_id, result, is_error = FALSE)` — update the
#'     tool card with the result.
#'     - `resultType = "table"`: pass `jsonlite::toJSON(df, auto_unbox = FALSE)`
#'     - `resultType = "file"`: pass base64 data URL
#'       (`paste0("data:text/csv;base64,", jsonlite::base64_enc(chartr(...)))`)
#'     - `resultType = "html"`: pass HTML string (rendered via
#'       `dangerouslySetInnerHTML`; only use with trusted tool output)
#'   * `attachments` — list of named lists, one per file the user attached.
#'     Each element has `type` (`"image"`, `"text"`, or `"file"`), `name`
#'     (filename), `data` (data-URL string for images, plain text for text
#'     files, base64 for other files), and optionally `contentType` (MIME
#'     type). Empty list `list()` when no attachments are present.
#'   * `is_reload` — `TRUE` when the user clicked "regenerate"; the handler
#'     receives the same `message` text and can remove the previous assistant
#'     turn from the LLM history before re-running.
#'   * `is_cancelled` — zero-argument function that returns `TRUE` once the
#'     user has clicked the stop button. Poll this inside your streaming loop
#'     to implement true server-side cancellation:
#'     ```r
#'     for (chunk in stream) {
#'       if (is_cancelled()) break
#'       on_chunk(chunk)
#'     }
#'     on_done()
#'     ```
#'     For [ClaudeAgentSDK](https://github.com/kaipingyang/ClaudeAgentSDK),
#'     call `client$interrupt()` when `is_cancelled()` returns `TRUE`.
#'   * `wait_for_approval` — `function(tool_call_id)` that returns a
#'     `promises::promise` which resolves to `TRUE` (approved) or `FALSE`
#'     (denied) once the user clicks Approve/Deny in the tool card UI.
#'     Use inside a `coro::async` `on_tool_request` callback to pause
#'     the stream until human approval:
#'     ```r
#'     chat$on_tool_request(coro::async(function(request) {
#'       on_tool_call(request@id, request@name, request@arguments,
#'                   list(requiresApproval = TRUE))
#'       approved <- coro::await(wait_for_approval(request@id))
#'       if (!approved) ellmer::tool_reject("User denied the tool call.")
#'     }))
#'     ```
#'
#'   * `register_cancel` — `function(fn)` that stores a cancel callback for
#'     the current thread. Call once before starting the stream with a function
#'     that performs true HTTP cancellation (e.g.
#'     `register_cancel(function() ctrl$cancel("Interrupted"))`).  When the
#'     user clicks Stop, `assistantUIServer` calls `fn()` immediately so the
#'     in-flight HTTP request is closed rather than silently drained.
#'
#'   All parameters except `message`, `on_chunk`, `on_done`, and `on_error`
#'   are optional: handlers that omit them continue to work unchanged.
#'
#'   The handler may return a promise (from `promises` or `coro`) for async
#'   streaming; errors from the promise are automatically forwarded via
#'   `on_error`.
#' @param show_thread_list Logical. If `TRUE`, a thread list sidebar is shown
#'   inside the widget for switching between conversations. Default `FALSE`
#'   (backward-compatible).
#' @param persistence Where thread history is persisted. `"client"` (default)
#'   restores and synchronizes browser `localStorage`; `"server"` treats
#'   `send_sessions()` snapshots as authoritative and never accesses
#'   `localStorage`; `"none"` keeps state only for the current page lifetime and
#'   likewise never accesses `localStorage`.
#' @param suggestions List of starter suggestion bubbles shown before the first
#'   message. Each element is a list with `prompt` (required, the text sent on
#'   click) and optional `text` (display label, defaults to `prompt`).
#' @param commands List of slash-command definitions. Each element is a list
#'   with `name` (e.g. `"summarize"`), `description`, `prompt` (the message
#'   sent when the command is submitted), and optional `category` (group label
#'   shown as a section header, such as `"Personal Skills"` or `"Project
#'   Skills"`).
#' @param action_items List of action-type slash-command items. Unlike
#'   `commands`, these do not send a message to the AI — instead, clicking them
#'   fires `on_action(id)` on the R side, allowing arbitrary server logic.
#'   Each element is a list with `section` (group label), `id` (unique string
#'   passed to `on_action`), optional `command` (the slash name shown and matched
#'   for exact direct input; defaults to `id`), `label`, and optional
#'   `description`. Example:
#'   ```r
#'   action_items = list(
#'     list(section = "Model",   id = "thinking-on",  label = "Enable thinking"),
#'     list(section = "Support", id = "view-docs",    label = "View help docs",
#'          description = "Open documentation")
#'   )
#'   ```
#' @param on_action `function(id)` called when the user clicks an item from
#'   `action_items`. `id` is the string from the item definition. Use this to
#'   trigger server-side logic (e.g. toggle a setting, open a URL, call
#'   `clear()`). `NULL` (default) means no handler is registered.
#' @param tools List of tool definitions for the \@ mention menu. Each element
#'   is a list with `name` and `description`. Typically mirrors the tools
#'   registered with ellmer.
#' @param ide_context_provider Optional zero-argument function sampled for every
#'   new user submission. It may return active file/selection metadata; selection
#'   text remains on the R side and is never sent to the browser.
#' @param workspace_search_provider Optional function accepting `query`, `kinds`,
#'   and `limit`, returning literal file/folder mention entries. Supplying it
#'   advertises the workspace mention capability.
#' @param code_theme Character string selecting the syntax-highlighting theme
#'   for code blocks. Available light themes: `"one-light"` (default),
#'   `"ghcolors"`, `"vs"`, `"solarized-light"`. Available dark themes:
#'   `"vsc-dark-plus"`, `"dracula"`, `"nord"`, `"night-owl"`, `"one-dark"`.
#' @param warming_label Optional character; cold-start indicator text (English).
#'   Defaults to a generic "Starting…". e.g. "Starting codeagent…".
#' @param welcome_message Optional character; empty-state greeting. Defaults to
#'   "How can I help you today?".
#' @param strings Optional named list for overriding UI text (tooltips, labels,
#'   placeholders). `NULL` (default) keeps all built-in English strings. Example
#'   for a Chinese UI:
#'   ```r
#'   strings = list(
#'     assistantMessage = list(
#'       copy   = list(tooltip = "复制"),
#'       reload = list(tooltip = "重新生成")
#'     ),
#'     editComposer = list(
#'       send   = list(label = "发送"),
#'       cancel = list(label = "取消")
#'     )
#'   )
#'   ```
#'
#' @param assistant_avatar Named list controlling the assistant's avatar.
#'   Fields: `fallback` (1–2 character string or emoji shown when no image is
#'   set), `src` (URL to an image), `alt` (alt text). Defaults to
#'   `list(fallback = "AI")`. Example with custom image:
#'   ```r
#'   assistant_avatar = list(src = "https://example.com/logo.png", fallback = "AI")
#'   ```
#' @param on_session_load Optional `function(session_id, thread_id, send_thread)`
#'   called when the frontend requests messages for a historical session thread.
#' @param on_feedback Optional `function(message_id, type)` called when the user
#'   clicks a 👍/👎 feedback button (`type` is `"positive"` or `"negative"`).
#' @param modal Logical. If `TRUE`, renders the chat as a floating modal bubble
#'   instead of an inline panel.
#' @param thread_max_width Optional CSS length capping the chat content width
#'   (e.g. `"44rem"`, `"800px"`). Default `NULL` = **full width** (fills the
#'   pane, like the Claude Code CLI / VS Code). Pass a length to center the
#'   conversation in a fixed-width column (assistant-ui's classic readable
#'   layout). Applies to messages, composer and the pinned-question bar together.
#' @param prewarm Logical (default `FALSE`). If `TRUE` and the `handler` exposes a
#'   `warmup` attribute (e.g. [make_claude_handler()]), pre-connect the initial
#'   thread's client on mount so the **first** message on that thread isn't slowed
#'   by the cold start (ClaudeSDKClient spawning the `claude` CLI subprocess).
#'   Historical sessions are warmed independently after `send_thread()` succeeds,
#'   regardless of this option; their warmups are deduplicated per thread and a
#'   failed warmup may be retried on a later load. A brief cold-start indicator is
#'   shown while connecting. Newly created blank threads remain lazy unless they
#'   are the initial thread covered by this one-shot option.
#'   **Left `FALSE` by default on purpose**: enabling it makes app startup attempt
#'   a backend connection at mount, so a slow/unreachable backend would stall the
#'   open (the default lazy connect only happens on the first message). Turn on
#'   only when the backend is reliably available at load.
#' @param on_rename Optional `function(thread_id, title)` called when the user
#'   renames a thread in the sidebar. The new title is already persisted
#'   client-side (localStorage); use this to sync server-side session stores.
#' @param on_open_file Optional `function(path, line = NULL)` called when the
#'   user clicks a file reference in a tool card, or after the assistant edits a
#'   file (the most recent successful edit of a run is revealed). The Claude
#'   addin wires this to `rstudioapi::navigateToFile()`; leave `NULL` (default)
#'   in browser contexts where no editor is available.
#' @param on_run_in_console Optional `function(code)` called when the user clicks
#'   "Run in Console" on an R code block. The Claude addin wires this to
#'   `rstudioapi::sendToConsole(code, execute = TRUE)` so the code runs in the user's
#'   live R session (visible, with their objects/packages/plots). When supplied, R code
#'   blocks show a run button. Leave `NULL` (default) outside RStudio.
#' @param on_archive_session Optional `function(session_id, archived)` called when
#'   the user archives (`archived = TRUE`) or unarchives (`FALSE`) a session in the
#'   sidebar. Use it to persist a server-authoritative soft-hide list so archived
#'   sessions stay hidden across reopens (the Claude addin stores this per project).
#' @param on_delete_session Optional `function(session_id)` called when the user
#'   confirms deleting a session. This is destructive: the Claude addin wires it to
#'   `ClaudeAgentSDK::delete_session()`, permanently removing the transcript from
#'   disk. The UI requires an explicit confirmation before invoking it.
#' @param theme Optional named list of theme tokens to recolor the widget, e.g.#'   from [assistant_theme()]. Colors may be hex/named/`rgb()` strings and are
#'   converted to assistant-ui's HSL-component format. Applied as scoped CSS
#'   variables on this widget only (multiple widgets can have different themes).
#'   Example: `theme = assistant_theme(primary = "#2563eb")`.
#' @param dark_mode Dark color scheme control: `FALSE` (light, default), `TRUE`
#'   (dark), or `"auto"` (follow the OS/browser `prefers-color-scheme`). A custom
#'   `theme` overrides individual tokens in either mode.
#' @param show_timestamps Logical. If `TRUE`, each user/assistant message shows
#'   its send time (HH:MM), derived from the message id. Defaults to `FALSE`.
#'
#'   * `on_session_load` — `function(session_id, thread_id, send_thread)` called
#'     when the frontend requests historical messages for a session thread. Used
#'     with `send_sessions()` (in the return value) to populate the sidebar with
#'     Claude Code sessions and lazy-load their messages on click.
#'     * `session_id` — the Claude session UUID
#'     * `thread_id` — the UI thread ID (equals `session_id` for imported threads)
#'     * `send_thread(messages)` — call with a list of `ThreadMessageLike` objects
#'       (each a named list with `id`, `role`, `content` fields) to populate the
#'       thread.
#'
#' @param on_edits Optional `function(edits)` called when the assistant proposes
#'   file edits (used by the addin to show edit markers).
#' @param working_dir Optional initial working directory shown in the
#'   working-directory picker (addin).
#' @param native_picker Logical; whether a native directory chooser is available
#'   (RStudio addin).
#' @param on_pick_working_dir Optional `function()` invoked to open the native
#'   working-directory picker.
#' @param on_set_working_dir Optional `function(path)` called when the working
#'   directory changes.
#' @param projects Optional character vector of saved working-directory favorites.
#' @param on_save_project Optional `function()` to save the current directory as a
#'   favorite.
#' @param on_remove_project Optional `function(path)` to remove a saved favorite.
#' @param files_pane_follow Optional logical initial state of the "Files pane
#'   follows working dir" toggle (`NULL` hides it).
#' @param on_toggle_files_pane_follow Optional `function(value)` called when that
#'   toggle changes.
#' @param auto_run Optional logical initial state of the auto-approve `run_r`
#'   toggle (`NULL` hides it).
#' @param on_toggle_auto_run Optional `function(value)` called when the auto-run
#'   toggle changes.
#' @param default_permission_mode Optional character; default permission mode for
#'   new conversations (addin preference, persisted).
#' @param on_set_default_permission_mode Optional `function(mode)` called when the
#'   default-mode preference changes.
#' @param mode_visibility Optional named list `list(showBypass=, showYolo=)`
#'   controlling which risky modes appear in the mode selector.
#' @param on_set_mode_visibility Optional `function(value)` called when mode
#'   visibility changes.
#' @param composer_density Optional character `"comfortable"` (default) or
#'   `"compact"` composer height preset.
#' @param on_set_composer_density Optional `function(value)` called when the
#'   composer height preset changes.
#' @param run_r_enabled Optional logical initial state of the `run_r` MCP tool
#'   toggle (`NULL` hides it).
#' @param on_toggle_run_r Optional `function(value)` called when the `run_r`
#'   toggle changes.
#' @param show_usage Logical (default `FALSE`); show the token-usage indicator.
#' @param context_window Optional integer context-window size for the usage
#'   indicator.
#' @param usage_style Character; usage indicator style, one of `"ring"`, `"bar"`,
#'   `"text"`.
#' @param latex Logical (default `FALSE`); enable KaTeX math rendering.
#' @param allow_warmup Logical (default `TRUE`); allow per-thread cold-start
#'   warmup of the handler.
#' @return A list with a `clear()` function that creates a new thread in the UI,
#'   `send_tool_call()` / `send_tool_result()` for manual tool card control, and
#'   `send_sessions(sessions)` for injecting a list of historical session stubs
#'   into the sidebar (each element: named list with `id`, `title`, `preview`,
#'   `createdAt` fields).
#' @export
assistantUIServer <- function(id, handler,
                              show_thread_list  = FALSE,
                              persistence       = c("client", "server", "none"),
                              suggestions       = list(),
                              commands          = list(),
                              tools             = list(),
                              action_items      = list(),
                              ide_context_provider = NULL,
                              workspace_search_provider = NULL,
                              on_action         = NULL,
                              on_session_load   = NULL,
                              on_feedback       = NULL,
                              on_rename         = NULL,
                              on_open_file      = NULL,
                              on_run_in_console = NULL,
                              on_edits          = NULL,
                              on_archive_session = NULL,
                              on_delete_session = NULL,
                              working_dir       = NULL,
                              native_picker     = FALSE,
                              on_pick_working_dir = NULL,
                              on_set_working_dir  = NULL,
                              projects          = NULL,
                              on_save_project   = NULL,
                              on_remove_project = NULL,
                              files_pane_follow = NULL,
                              on_toggle_files_pane_follow = NULL,
                              auto_run = NULL,
                              on_toggle_auto_run = NULL,
                              default_permission_mode = NULL,
                              on_set_default_permission_mode = NULL,
                              mode_visibility = NULL,
                              on_set_mode_visibility = NULL,
                              composer_density = NULL,
                              on_set_composer_density = NULL,
                              run_r_enabled = NULL,
                              on_toggle_run_r = NULL,
                              thread_max_width = NULL,
                              show_usage        = FALSE,
                              context_window    = NULL,
                              usage_style       = c("ring", "bar", "text"),
                              latex             = FALSE,
                              code_theme        = "one-light",
                              strings           = NULL,
                              warming_label     = NULL,
                              welcome_message   = NULL,
                              assistant_avatar  = list(fallback = "AI"),
                              theme             = NULL,
                              dark_mode         = FALSE,
                              show_timestamps   = FALSE,
                              modal             = FALSE,
                              prewarm           = FALSE,
                              allow_warmup      = TRUE) {
  force(show_thread_list); force(suggestions); force(commands)
  persistence <- tryCatch(
    match.arg(persistence),
    error = function(e) stop(
      "`persistence` must be one of \"client\", \"server\", or \"none\".",
      call. = FALSE
    )
  )
  force(tools); force(action_items); force(on_action); force(on_session_load)
  force(ide_context_provider); force(workspace_search_provider)
  force(on_feedback); force(modal)
  force(on_rename)
  force(on_open_file)
  force(on_archive_session)
  force(on_delete_session)
  # 若 handler 暴露了内置动作分发器(如 make_claude_handler 的 ClaudeSDKClient 控制操作)
  # 且用户未自定义 on_action,则自动接线,使 /model、/clear 等客户端动作开箱即用。
  # 只有该 dispatcher 实际生效时才发布配套 capability；否则 UI 会把 permission
  # action 发送给不相关的自定义回调并永久 pending。
  .handler_action <- attr(handler, "action_handler")
  .uses_handler_action <- !is.null(.handler_action) &&
    (is.null(on_action) || identical(on_action, .handler_action))
  if (is.null(on_action) && !is.null(.handler_action)) on_action <- .handler_action
  .ui_capabilities <- if (.uses_handler_action) attr(handler, "ui_capabilities") else NULL
  if (is.null(.ui_capabilities)) .ui_capabilities <- list()
  if (is.function(ide_context_provider) || is.function(workspace_search_provider)) {
    .ui_capabilities$contract_version <- 1L
  }
  if (is.function(ide_context_provider)) {
    .ui_capabilities$ide_context <- list(
      submit = TRUE, preview = TRUE, selection_visibility = TRUE
    )
  }
  if (is.function(workspace_search_provider)) {
    .ui_capabilities$workspace_mentions <- list(
      search = TRUE, kinds = c("file", "folder"), line_ranges = TRUE, literal = TRUE
    )
  }
  if (!length(.ui_capabilities)) .ui_capabilities <- NULL
  force(code_theme); force(strings); force(assistant_avatar)
  force(warming_label); force(welcome_message)
  force(theme); force(dark_mode)
  force(show_timestamps)
  session  <- shiny::getDefaultReactiveDomain()
  input_id <- paste0(id, "_input")

  # dark_mode 归一化:TRUE/FALSE/"auto"
  if (is.logical(dark_mode)) dark_mode <- isTRUE(dark_mode)
  else if (!identical(dark_mode, "auto"))
    stop("`dark_mode` must be TRUE, FALSE, or \"auto\".")

  config <- list(
    show_thread_list = show_thread_list,
    persistence      = persistence,
    suggestions      = suggestions,
    commands         = commands,
    tools            = tools,
    action_items     = action_items,
    code_theme       = code_theme,
    dark_mode        = dark_mode,
    show_timestamps  = show_timestamps,
    modal            = modal
  )
  normalized_theme <- .normalize_theme(theme)
  if (!is.null(normalized_theme))  config$theme            <- normalized_theme
  if (!is.null(strings))          config$strings          <- strings
  if (!is.null(warming_label))    config$warming_label    <- as.character(warming_label)[[1L]]
  if (!is.null(welcome_message))  config$welcome_message  <- as.character(welcome_message)[[1L]]
  if (!is.null(assistant_avatar)) config$assistant_avatar <- assistant_avatar
  if (!is.null(.ui_capabilities)) config$ui_capabilities  <- .ui_capabilities
  # 工作目录选择器（addin）：初始目录 + 是否有原生目录选择弹窗（RStudio）。
  if (!is.null(working_dir)) {
    config$working_dir   <- as.character(working_dir)[[1L]]
    config$native_picker <- isTRUE(native_picker)
  }
  # 工作目录收藏夹初始列表（addin）。
  if (!is.null(projects)) config$projects <- as.list(as.character(projects))
  # Files 面板跟随开关初始态（addin/RStudio；NULL = 不显示该开关）。
  if (!is.null(files_pane_follow)) config$files_pane_follow <- isTRUE(files_pane_follow)
  # 角度 B:自动批准 run_r 开关(仅当能力存在,即 on_toggle_auto_run 提供时暴露)。
  if (!is.null(auto_run)) config$auto_run <- isTRUE(auto_run)
  # Settings 偏好(Plan 45):新会话默认权限模式 + 危险模式可见性(隐藏 Bypass/YOLO)。
  # 仅当 addin 提供对应回调时暴露(非 addin 用法 config 不含 → 前端行为不变)。
  if (!is.null(default_permission_mode))
    config$default_permission_mode <- as.character(default_permission_mode)[[1L]]
  if (!is.null(mode_visibility))
    config$mode_visibility <- list(
      showBypass = isTRUE(mode_visibility$showBypass %||% mode_visibility$show_bypass),
      showYolo   = isTRUE(mode_visibility$showYolo   %||% mode_visibility$show_yolo)
    )
  # Plan 45:输入框高度预设(comfortable/compact)。
  if (!is.null(composer_density))
    config$composer_density <- as.character(composer_density)[[1L]]
  # Plan 45:run_r MCP 开关(仅当 run_r 可用,即 on_toggle_run_r 提供时暴露)。
  if (!is.null(run_r_enabled)) config$run_r_enabled <- isTRUE(run_r_enabled)
  # 对话内容最大宽度(Plan 23)。NULL = 满宽(默认,像 CLI/VS Code);传 CSS 长度(如
  # "44rem"/"800px")= 居中限宽。前端缺省解析为 "none"(满宽)。
  if (!is.null(thread_max_width)) {
    config$thread_max_width <- as.character(thread_max_width)[[1L]]
  }
  # Token 用量显示(Plan 33,opt-in)。context_window 由调用方按模型给(Claude 200k 等)。
  if (isTRUE(show_usage) && !is.null(context_window)) {
    config$show_usage     <- TRUE
    config$context_window <- as.integer(context_window)[[1L]]
    config$usage_style    <- match.arg(usage_style)
  }
  # LaTeX 数学(Plan 34,opt-in)。开启后前端加载 KaTeX CSS(CDN)并启用 remark-math/rehype-katex。
  if (isTRUE(latex)) config$latex <- TRUE
  # R console 交互（addin/RStudio）：提供 on_run_in_console 时,前端在 R 代码块上显示"Run in Console"。
  if (is.function(on_run_in_console)) config$console_run <- TRUE

  session$output[[id]] <- renderAssistantUI(
    config   = config,
    outputId = id
  )

  # 每线程 cancel 标志（mutable environment，cancel 信号到达时设为 TRUE）
  cancel_flags <- new.env(parent = emptyenv())
  # 每线程注册的 cancel 函数（handler 注入，cancel 信号到达时立即调用）
  cancel_fns <- new.env(parent = emptyenv())

  # ── 消息回调工厂（按 thread_id 构建，消息携带 threadId 供 JS 路由）──────────
  # 旧版：静态回调，所有 thread 共用一个 callbacks slot，切 thread 时旧 handler
  # 的 onDone 会错误清掉新 thread 的 running 状态，旧消息也可能串入新 thread。
  # 新版：每次 ExtendedTask 启动时动态构建，消息携带 threadId，JS 按 threadId 路由。
  make_callbacks <- function(thread_id) {
    # 任务 D：per-run 编辑揭示 tracker——run 结束只揭示最近一次成功编辑的文件。
    edit_reveal <- .new_edit_reveal_tracker()
    list(
      on_chunk = function(text) {
        session$sendCustomMessage(paste0(input_id, ":chunk"),
                                  list(text = text, threadId = thread_id))
      },
      on_done = function(suggestions = list()) {
        if (!is.null(on_open_file)) {
          reveal_path <- edit_reveal$flush()
          if (!is.null(reveal_path)) {
            tryCatch(on_open_file(reveal_path, NULL), error = function(e) NULL)
          }
        }
        # 本轮所有成功编辑 → on_edits（addin 用于 Markers 面板可跳转清单）。始终 take 以清空累积。
        run_edits <- edit_reveal$take_edits()
        if (!is.null(on_edits) && length(run_edits))
          tryCatch(on_edits(run_edits), error = function(e) NULL)
        session$sendCustomMessage(paste0(input_id, ":done"),
                                  list(suggestions = suggestions, threadId = thread_id))
      },
      on_error_fn = function(msg) {
        session$sendCustomMessage(paste0(input_id, ":error"),
                                  list(message = msg, threadId = thread_id))
      },
      on_tool_call = function(tool_call_id, tool_name, args = list(), annotations = list()) {
        # 注入 inputId，使前端审批 UI 能定位到本 widget 实例的 approval handler
        # （多 widget 同页时模块级单例会串台，靠 inputId 路由隔离）。
        annotations$inputId <- input_id
        # Edit 工具：算 old_string 在文件里的真实起始行 → 前端 diff 显示真实行号(非从 1)。
        # 仅单个 Edit;MultiEdit 多段不同起始行,暂不注入(前端退回 1-based)。
        if (identical(tool_name, "Edit") && is.null(annotations$diffStartLine)) {
          sl <- tryCatch(
            .tool_edit_start_line(args$file_path, args$old_string, working_dir),
            error = function(e) NULL
          )
          if (!is.null(sl)) annotations$diffStartLine <- sl
        }
        edit_reveal$note_call(tool_call_id, tool_name, args)
        session$sendCustomMessage(
          paste0(input_id, ":tool-call"),
          list(
            toolCallId  = tool_call_id,
            toolName    = tool_name,
            args        = args,
            argsText    = as.character(jsonlite::toJSON(args, auto_unbox = TRUE, pretty = FALSE)),
            annotations = annotations,
            threadId    = thread_id
          )
        )
      },
      on_tool_call_start = function(tool_call_id, tool_name, annotations = list()) {
        session$sendCustomMessage(
          paste0(input_id, ":tool-call-start"),
          list(
            toolCallId  = tool_call_id,
            toolName    = tool_name,
            annotations = annotations,
            threadId    = thread_id
          )
        )
      },
      on_tool_call_delta = function(tool_call_id, delta) {
        session$sendCustomMessage(
          paste0(input_id, ":tool-call-delta"),
          list(toolCallId = tool_call_id, delta = delta, threadId = thread_id)
        )
      },
      on_tool_result = function(tool_call_id, result, is_error = FALSE) {
        edit_reveal$note_result(tool_call_id, is_error)
        session$sendCustomMessage(
          paste0(input_id, ":tool-result"),
          list(toolCallId = tool_call_id, result = result, isError = is_error, threadId = thread_id)
        )
      },
      on_thinking = function(text) {
        session$sendCustomMessage(paste0(input_id, ":thinking"),
                                  list(text = text, threadId = thread_id))
      },
      on_source = function(url, title = NULL, id = NULL) {
        session$sendCustomMessage(paste0(input_id, ":source"),
                                  list(url = url, title = title, id = id, threadId = thread_id))
      },
      on_image = function(image) {
        session$sendCustomMessage(paste0(input_id, ":image"),
                                  list(image = image, threadId = thread_id))
      },
      # Plan 47 A0 — Data UI:把一个具名数据事件下发为当前 assistant 消息的一个
      # `data-<name>` part(前端 DATA_UI_BY_NAME[name] 渲染)。`data` 为任意 R 列表
      # (经 Shiny 序列化);表格/流程图用 gui_table()/gui_flow() 构造更省心。
      on_data_ui = function(name, data = NULL) {
        session$sendCustomMessage(paste0(input_id, ":data-ui"),
                                  list(name = name, data = data, threadId = thread_id))
      },
      # Plan 47 A1 — Generative-UI primitive:下发一个 {root:{component,props,children}} 布局
      # spec 为当前消息的 generative-ui part(前端用 shinyAllowlist 渲染,未知组件走 Fallback)。
      on_generative_ui = function(spec) {
        session$sendCustomMessage(paste0(input_id, ":generative-ui"),
                                  list(spec = spec, threadId = thread_id))
      },
      on_artifact = function(id, title, content, type = "markdown", lang = NULL) {
        session$sendCustomMessage(paste0(input_id, ":artifact"),
                                  list(id = id, title = title, type = type,
                                       content = content, lang = lang, threadId = thread_id))
      },
      # ── ClaudeAgentSDK 能力对齐 ────────────────────────────────────────────
      # #1 成本/用量:ResultMessage 的 total_cost_usd / tokens / turns / duration。
      on_usage = function(cost_usd = NULL, tokens = NULL, context_tokens = NULL, turns = NULL,
                          duration_ms = NULL, model = NULL, context_window = NULL) {
        session$sendCustomMessage(paste0(input_id, ":usage"),
                                  list(costUsd = cost_usd, tokens = tokens,
                                       contextTokens = context_tokens, turns = turns,
                                       durationMs = duration_ms, model = model,
                                       contextWindow = context_window,
                                       threadId = thread_id))
      },
      # #2 子agent/Task 进度:kind = "started" | "progress" | "notification"。
      on_task = function(task_id, kind, description = NULL, status = NULL,
                         tool_name = NULL, summary = NULL) {
        session$sendCustomMessage(paste0(input_id, ":task"),
                                  list(taskId = task_id, kind = kind, description = description,
                                       status = status, toolName = tool_name, summary = summary,
                                       threadId = thread_id))
      },
      # #3 限流告警。
      on_rate_limit = function(status = NULL, resets_at = NULL, utilization = NULL, type = NULL) {
        session$sendCustomMessage(paste0(input_id, ":rate-limit"),
                                  list(status = status, resetsAt = resets_at,
                                       utilization = utilization, type = type,
                                       threadId = thread_id))
      },
      # #4 系统状态行:subtype = status/thinking_tokens/init 等。
      on_status = function(status, text = NULL) {
        session$sendCustomMessage(paste0(input_id, ":status"),
                                  list(status = status, text = text, threadId = thread_id))
      },
      # #5 命令自动发现:get_server_info() 拉到的 CLI slash 命令 + output styles。
      on_commands = function(commands = list(), output_styles = list()) {
        session$sendCustomMessage(paste0(input_id, ":server-commands"),
                                  list(commands = commands, outputStyles = output_styles,
                                       threadId = thread_id))
      },
      # 每线程冷启动指示:client 首次连接(spawn CLI 子进程)期间 active=TRUE。
      on_warming = function(active, resuming = FALSE) {
        session$sendCustomMessage(paste0(input_id, ":warming"),
                                  list(active = isTRUE(active), resuming = isTRUE(resuming),
                                       threadId = thread_id))
      },
      # Agent 共享状态(Plan 36):handler 调 on_state(list) 推送任意 per-thread 状态快照,
      # 前端 useShinyAgentState() 订阅。
      on_state = function(state) {
        session$sendCustomMessage(paste0(input_id, ":state-snapshot"),
                                  list(state = state, threadId = thread_id))
      }
    )
  }

  # ── IDE context / workspace mention RPC ─────────────────────────────────────
  # Preview responses contain metadata only. The selection body is sampled again
  # at submit time and is never round-tripped through the browser.
  if (is.function(ide_context_provider)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_ide_context_refresh")]], {
      msg <- session$input[[paste0(input_id, "_ide_context_refresh")]]
      if (is.null(msg)) return()
      context <- .read_ide_context(ide_context_provider, selection_visible = TRUE)
      payload <- .ide_context_metadata(context) %||% list()
      payload$requestId <- msg$requestId
      payload$threadId <- msg$threadId
      session$sendCustomMessage(paste0(input_id, ":ide-context"), payload)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 工作目录选择器：UI 请求原生弹窗 / 手输路径 → 交回调（addin 负责切目录+重连+重推）。
  if (is.function(on_pick_working_dir)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_pick_working_dir")]], {
      tryCatch(on_pick_working_dir(), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  if (is.function(on_set_working_dir)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_set_working_dir")]], {
      msg <- session$input[[paste0(input_id, "_set_working_dir")]]
      if (is.null(msg)) return()
      path <- if (is.list(msg)) msg$path else msg
      tryCatch(on_set_working_dir(as.character(path %||% "")), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  # 收藏夹：保存当前目录 / 删除某收藏（addin 持久化 + 回推列表）。
  if (is.function(on_save_project)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_save_project")]], {
      tryCatch(on_save_project(), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  if (is.function(on_remove_project)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_remove_project")]], {
      msg <- session$input[[paste0(input_id, "_remove_project")]]
      if (is.null(msg)) return()
      path <- if (is.list(msg)) msg$path else msg
      tryCatch(on_remove_project(as.character(path %||% "")), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  # Files 面板跟随开关切换（addin 持久化偏好）。
  if (is.function(on_toggle_files_pane_follow)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_files_pane_follow")]], {
      msg <- session$input[[paste0(input_id, "_files_pane_follow")]]
      if (is.null(msg)) return()
      value <- if (is.list(msg)) msg$value else msg
      tryCatch(on_toggle_files_pane_follow(isTRUE(value)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 角度 B:自动批准 run_r 开关切换 → 委派给 addin(set_autorun → reset_clients)。
  if (is.function(on_toggle_auto_run)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_auto_run_enabled")]], {
      msg <- session$input[[paste0(input_id, "_auto_run_enabled")]]
      if (is.null(msg)) return()
      value <- if (is.list(msg)) msg$value else msg
      tryCatch(on_toggle_auto_run(isTRUE(value)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # Plan 45:Settings 偏好回调 —— 新会话默认模式 / 危险模式可见性。
  if (is.function(on_set_default_permission_mode)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_default_permission_mode")]], {
      msg <- session$input[[paste0(input_id, "_default_permission_mode")]]
      if (is.null(msg)) return()
      value <- if (is.list(msg)) msg$value else msg
      tryCatch(on_set_default_permission_mode(as.character(value)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  if (is.function(on_set_mode_visibility)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_mode_visibility")]], {
      msg <- session$input[[paste0(input_id, "_mode_visibility")]]
      if (is.null(msg)) return()
      tryCatch(on_set_mode_visibility(list(
        showBypass = isTRUE(msg$showBypass), showYolo = isTRUE(msg$showYolo)
      )), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  if (is.function(on_set_composer_density)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_composer_density")]], {
      msg <- session$input[[paste0(input_id, "_composer_density")]]
      if (is.null(msg)) return()
      value <- if (is.list(msg)) msg$value else msg
      tryCatch(on_set_composer_density(as.character(value)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  if (is.function(on_toggle_run_r)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_run_r_enabled")]], {
      msg <- session$input[[paste0(input_id, "_run_r_enabled")]]
      if (is.null(msg)) return()
      value <- if (is.list(msg)) msg$value else msg
      tryCatch(on_toggle_run_r(isTRUE(value)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  if (is.function(workspace_search_provider)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_workspace_search")]], {
      msg <- session$input[[paste0(input_id, "_workspace_search")]]
      if (is.null(msg)) return()
      limit <- suppressWarnings(as.integer(msg$limit %||% 50L))
      if (is.na(limit)) limit <- 50L
      args <- list(
        query = as.character(msg$query %||% ""),
        kinds = as.character(msg$kinds %||% c("file", "folder")),
        limit = max(1L, min(100L, limit))
      )
      params <- names(formals(workspace_search_provider))
      call_args <- if ("..." %in% params) args else args[names(args) %in% params]
      items <- tryCatch(do.call(workspace_search_provider, call_args), error = function(e) list())
      session$sendCustomMessage(
        paste0(input_id, ":workspace-results"),
        list(requestId = msg$requestId, threadId = msg$threadId, items = items %||% list())
      )
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # ── tool 审批 ────────────────────────────────────────────────────────────────
  # wait_for_approval 用 observeEvent 驱动。
  # 关键：handler 必须通过 ExtendedTask 启动（见下方 stream_task），
  # 只有 ExtendedTask 才允许 Shiny reactive flush 在 coro::await 挂起期间运行；
  # 直接从 observeEvent 里启动 handler 则不会触发 reactive flush，导致审批 observer 死锁。
  # 每个 resolver 记录所属 thread_id，使 cancel 只否决本线程的挂起审批（多线程隔离）。
  approval_resolvers <- new.env(parent = emptyenv())

  shiny::observeEvent(session$input[[paste0(input_id, "_tool_approval")]], {
    msg <- session$input[[paste0(input_id, "_tool_approval")]]
    if (is.null(msg)) return()
    tid <- msg$toolCallId
    entry <- get0(tid, envir = approval_resolvers)
    if (!is.null(entry)) {
      rm(list = tid, envir = approval_resolvers)
      entry$fn(msg)  # 传回完整 msg，handler 自行解析
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # 工厂：绑定 thread_id，返回该线程专用的 wait_for_approval。
  make_wait_for_approval <- function(thread_id) {
    function(tool_call_id) {
      promises::promise(function(resolve, reject) {
        assign(tool_call_id, list(fn = resolve, thread = thread_id),
               envir = approval_resolvers)
      })
    }
  }

  # action_items 点击 → 通知 on_action 回调
  if (!is.null(on_action)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_action")]], {
      msg <- session$input[[paste0(input_id, "_action")]]
      if (is.null(msg)) return()
      tid <- msg$threadId
      # 向 UI 回传动作结果。requestId/actionId 用于并发关联；value 为可选 canonical 状态。
      send_action_result <- function(message, status = "ok", value = NULL) {
        session$sendCustomMessage(
          paste0(input_id, ":action-result"),
          list(threadId = tid, requestId = msg$requestId, actionId = msg$id,
               message = message, status = status, value = value)
        )
      }
      all_args <- list(id = msg$id, thread_id = tid, send_action_result = send_action_result)
      pars <- names(formals(on_action))
      call_args <- if ("..." %in% pars) all_args else all_args[names(all_args) %in% pars]
      do.call(on_action, call_args)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 反馈按钮（👍/👎）→ on_feedback 回调
  if (!is.null(on_feedback)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_feedback")]], {
      fb <- session$input[[paste0(input_id, "_feedback")]]
      if (is.null(fb)) return()
      on_feedback(fb$messageId, fb$type)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 线程重命名 → on_rename 回调（前端已本地持久化标题;此回调供 server 端
  # session 存储同步,如更新 SQLite 里的 session title）
  if (!is.null(on_rename)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_rename")]], {
      rn <- session$input[[paste0(input_id, "_rename")]]
      if (is.null(rn)) return()
      on_rename(rn$threadId, rn$title)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 点击文件引用 → on_open_file 回调（addin 用 rstudioapi::navigateToFile 在编辑器打开）。
  if (!is.null(on_open_file)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_open_file")]], {
      of <- session$input[[paste0(input_id, "_open_file")]]
      if (is.null(of) || is.null(of$path) || !nzchar(of$path)) return()
      line <- suppressWarnings(as.integer(of$line))
      if (length(line) != 1L || is.na(line)) line <- NULL
      tryCatch(on_open_file(of$path, line), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }
  # 代码块"Run in Console" → 在用户的活 R 会话执行,并把捕获结果回传前端(喂给 Claude)。
  if (is.function(on_run_in_console)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_run_in_console")]], {
      msg <- session$input[[paste0(input_id, "_run_in_console")]]
      if (is.null(msg)) return()
      code <- if (is.list(msg)) msg$code else msg
      code <- as.character(code %||% "")
      if (!nzchar(code)) return()
      res <- tryCatch(on_run_in_console(code),
                      error = function(e) list(ok = FALSE, output = "", error = conditionMessage(e)))
      if (is.list(res)) {
        session$sendCustomMessage(paste0(input_id, ":console-result"), list(
          code   = code,
          ok     = isTRUE(res$ok),
          output = as.character(res$output %||% ""),
          error  = as.character(res$error %||% "")
        ))
      }
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 方案B：Archive 软隐藏（可恢复，持久化在服务端）。
  if (!is.null(on_archive_session)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_archive_session")]], {
      ev <- session$input[[paste0(input_id, "_archive_session")]]
      if (is.null(ev) || is.null(ev$sessionId) || !nzchar(ev$sessionId)) return()
      tryCatch(on_archive_session(ev$sessionId, isTRUE(ev$archived)), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 方案B：Delete 真删磁盘 transcript（不可逆，前端已二次确认）。
  if (!is.null(on_delete_session)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_delete_session")]], {
      ev <- session$input[[paste0(input_id, "_delete_session")]]
      if (is.null(ev) || is.null(ev$sessionId) || !nzchar(ev$sessionId)) return()
      tryCatch(on_delete_session(ev$sessionId), error = function(e) NULL)
    }, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # 独立 observer 监听 cancel 信号
  shiny::observeEvent(session$input[[paste0(input_id, "_cancel")]], {
    msg <- session$input[[paste0(input_id, "_cancel")]]
    if (is.null(msg)) return()
    tid <- msg$threadId %||% "default"
    assign(tid, TRUE, envir = cancel_flags)
    # 调用 handler 注册的 cancel fn（如 stream_controller$cancel()），实现真 HTTP 取消。
    cancel_fn <- get0(tid, envir = cancel_fns)
    if (!is.null(cancel_fn)) {
      rm(list = tid, envir = cancel_fns)
      tryCatch(cancel_fn(), error = function(e) NULL)
    }
    # 自动以 denied resolve 本线程挂起的 wait_for_approval promise，
    # 避免 handler 在 coro::await(wait_for_approval(...)) 处死锁。
    # 仅否决属于被取消线程的审批，不影响其它线程（多线程隔离）。
    for (key in ls(approval_resolvers)) {
      entry <- get0(key, envir = approval_resolvers)
      if (!is.null(entry) && identical(entry$thread, tid)) {
        rm(list = key, envir = approval_resolvers)
        tryCatch(entry$fn(list(approved = FALSE, toolCallId = key)), error = function(e) NULL)
      }
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # ── ExtendedTask：以 Shiny-aware 异步任务运行 handler ────────────────────────
  # ExtendedTask 让 Shiny 知道有长时任务在运行，允许 reactive flush 在 await 期间发生，
  # 从而 _tool_approval / _cancel 等 observer 可以正常触发。
  stream_task <- shiny::ExtendedTask$new(
    function(msg_text, thread_id, is_reload, attachments, ide_context) {
      cbs <- make_callbacks(thread_id)
      is_cancelled <- function() isTRUE(get0(thread_id, envir = cancel_flags))
      register_cancel <- function(fn) assign(thread_id, fn, envir = cancel_fns)
      wait_for_approval <- make_wait_for_approval(thread_id)

      all_args <- list(
        message           = msg_text,
        thread_id         = thread_id,
        on_chunk          = cbs$on_chunk,
        on_done           = cbs$on_done,
        on_error          = cbs$on_error_fn,
        on_tool_call      = cbs$on_tool_call,
        on_tool_call_start = cbs$on_tool_call_start,
        on_tool_call_delta = cbs$on_tool_call_delta,
        on_tool_result    = cbs$on_tool_result,
        on_thinking       = cbs$on_thinking,
        on_source         = cbs$on_source,
        on_image          = cbs$on_image,
        on_data_ui        = cbs$on_data_ui,
        on_generative_ui  = cbs$on_generative_ui,
        on_artifact       = cbs$on_artifact,
        on_usage          = cbs$on_usage,
        on_task           = cbs$on_task,
        on_rate_limit     = cbs$on_rate_limit,
        on_status         = cbs$on_status,
        on_warming        = cbs$on_warming,
        on_state          = cbs$on_state,
        on_commands       = cbs$on_commands,
        attachments       = attachments,
        is_reload         = is_reload,
        is_cancelled      = is_cancelled,
        wait_for_approval = wait_for_approval,
        register_cancel   = register_cancel,
        ide_context       = ide_context
      )
      handler_params <- names(formals(handler))
      call_args <- if ("..." %in% handler_params) all_args
                   else all_args[names(all_args) %in% handler_params]

      result <- tryCatch(
        do.call(handler, call_args),
        error = function(e) { cbs$on_error_fn(conditionMessage(e)); NULL }
      )
      if (inherits(result, "promise")) {
        promises::catch(result, function(e) { cbs$on_error_fn(conditionMessage(e)); NULL })
      } else {
        promises::promise_resolve(NULL)
      }
    }
  )

  # ── sessions ready 握手：JS handler 注册后补发 sessions ────────────────────
  # React 18 createRoot().render() 是异步的，Shiny 首次 flush 时 :sessions
  # handler 尚未注册，消息被静默丢弃。JS ready 信号到达后，用缓存的 sessions 补发。
  pending_sessions <- NULL

  # Historical sessions always warm after their messages are delivered, even
  # when initial prewarm is disabled. State is per thread: concurrent/repeated
  # loads deduplicate, success stays warm, and failure removes the marker so a
  # later load can retry.
  .warmup_fn <- attr(handler, "warmup")
  warmup_states <- new.env(parent = emptyenv())
  schedule_warmup <- function(thread_id, delay = 0) {
    # 角度 B:run_r 进程内 MCP server 存在时,提前预热(连接后闲置)会触发 CLI 侧
    # 首条消息 ~55s 卡顿(见 Plan 22)。此时禁用一切 warm-ahead,让连接发生在首条
    # 消息发送时(connect+send 相邻 = 快路径)。
    if (!isTRUE(allow_warmup)) return(invisible(FALSE))
    if (!is.function(.warmup_fn) || is.null(thread_id) ||
        !nzchar(thread_id %||% "")) return(invisible(FALSE))
    state <- get0(thread_id, envir = warmup_states, inherits = FALSE)
    if (!is.null(state) && state %in% c("warming", "warmed")) {
      return(invisible(FALSE))
    }

    assign(thread_id, "warming", envir = warmup_states)
    cbs <- make_callbacks(thread_id)
    later::later(function() {
      # 历史 session 的 warmup = 恢复既有对话，resuming=TRUE。
      tryCatch(cbs$on_warming(TRUE, TRUE), error = function(e) NULL)
      # Yield once more so the warming signal can flush before a blocking CLI
      # connection. This also guarantees load_session itself stays non-blocking.
      later::later(function() {
        succeeded <- tryCatch(
          {
            .warmup_fn(thread_id)
            TRUE
          },
          interrupt = function(e) FALSE,
          error = function(e) FALSE
        )
        tryCatch(cbs$on_warming(FALSE), error = function(e) NULL)
        if (isTRUE(succeeded)) {
          assign(thread_id, "warmed", envir = warmup_states)
        } else if (exists(thread_id, envir = warmup_states, inherits = FALSE)) {
          rm(list = thread_id, envir = warmup_states)
        }
      }, 0.05)
    }, delay)
    invisible(TRUE)
  }

  shiny::observeEvent(session$input[[paste0(input_id, "_sessions_ready")]], {
    if (!is.null(pending_sessions)) {
      session$sendCustomMessage(paste0(input_id, ":sessions"), pending_sessions)
    }
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  shiny::observeEvent(session$input[[input_id]], {
    msg <- session$input[[input_id]]
    if (is.null(msg)) return()
    # History requests have no text field and never enter stream_task.
    is_initial_history <- identical(msg$type, "load_session")
    is_older_history <- identical(msg$type, "load_session_page")
    is_history_request <- is_initial_history || is_older_history
    if (!is_history_request && !nzchar(trimws(msg$text %||% ""))) return()

    if (is_history_request && !is.null(on_session_load)) {
      send_thread <- function(messages, cursor = NULL, has_more = FALSE) {
        session$sendCustomMessage(
          paste0(input_id, ":load-thread"),
          list(
            threadId = msg$threadId,
            messages = messages,
            cursor = cursor,
            hasMore = isTRUE(has_more),
            prepend = is_older_history
          )
        )
        # Restoring the SDK conversation is a distinct second phase. Loading an
        # older UI page must not reconnect or warm the same thread again.
        if (is_initial_history) schedule_warmup(msg$threadId)
      }
      .call_history_callback(on_session_load, list(
        session_id = msg$sessionId,
        thread_id = msg$threadId,
        send_thread = send_thread,
        cursor = if (is_older_history) msg$cursor else NULL,
        limit = msg$limit %||% 50L
      ))
      return()
    }

    thread_id <- msg$threadId %||% "default"
    is_reload <- identical(msg$type, "reload")
    selection_visible <- !identical(msg$ideContext$selectionVisible, FALSE)
    # Reload 重跑历史 prompt，不附加任意旧/当前 selection；普通新提交则在
    # observer 收到消息的同一时刻采样 provider，形成该 run 的不可变快照。
    ide_context <- if (!is_reload && is.function(ide_context_provider))
      .read_ide_context(ide_context_provider, selection_visible)
    else NULL

    # 新 run 开始前重置 cancel 标志和 cancel fn
    assign(thread_id, FALSE, envir = cancel_flags)
    if (exists(thread_id, envir = cancel_fns)) rm(list = thread_id, envir = cancel_fns)

    stream_task$invoke(
      msg$text,
      thread_id,
      is_reload,
      msg$attachments %||% list(),
      ide_context
    )
  }, ignoreNULL = TRUE, ignoreInit = TRUE)

  # Initial blank-thread warmup remains opt-in and one-shot. Historical loads
  # call schedule_warmup independently above and are not gated by this observer.
  if (isTRUE(prewarm) && is.function(.warmup_fn)) {
    shiny::observeEvent(session$input[[paste0(input_id, "_warmup")]], {
      msg <- session$input[[paste0(input_id, "_warmup")]]
      tid <- if (is.list(msg)) msg$threadId else NULL
      schedule_warmup(tid, delay = 0.1)
    }, once = TRUE, ignoreNULL = TRUE, ignoreInit = TRUE)
  }

  # session 结束时回收 handler 持有的资源（如 ClaudeSDKClient 子进程）。
  # handler 可选通过 attr(handler, "cleanup") 暴露清理函数；ellmer handler 无此 attr 则跳过。
  handler_cleanup <- attr(handler, "cleanup")
  if (is.function(handler_cleanup)) {
    session$onSessionEnded(function() {
      .run_handler_cleanup(handler_cleanup)
    })
  }

  invisible(list(
    clear = function() {
      session$sendCustomMessage(paste0(input_id, ":clear"), list())
    },
    # 注意：thread_id 默认 "default"。若用户已新建/切换线程（id 为随机生成值），
    # 必须显式传入当前 thread_id，否则消息路由到不存在的 "default" 线程被静默丢弃。
    send_tool_call = function(tool_call_id, tool_name, args = list(), thread_id = "default") {
      cbs <- make_callbacks(thread_id)
      cbs$on_tool_call(tool_call_id, tool_name, args)
    },
    send_tool_result = function(tool_call_id, result, is_error = FALSE, thread_id = "default") {
      cbs <- make_callbacks(thread_id)
      cbs$on_tool_result(tool_call_id, result, is_error)
    },
    send_sessions = function(sessions) {
      pending_sessions <<- sessions
      session$sendCustomMessage(paste0(input_id, ":sessions"), sessions)
    },
    # 本地 skills / commands 热更新(切换工作目录后重载新项目 .claude 的 skills)。
    send_commands = function(commands) {
      session$sendCustomMessage(paste0(input_id, ":commands"),
                                list(commands = commands))
    },
    # 推送当前工作目录 + 最近目录列表给 UI（切目录时先发这个，再重推 sessions）。
    send_working_dir = function(dir, recent = list()) {
      session$sendCustomMessage(paste0(input_id, ":working-dir"),
                                list(dir = dir, recent = recent))
    },
    # 推送工作目录收藏夹列表给 UI。
    send_projects = function(projects) {
      session$sendCustomMessage(paste0(input_id, ":projects"),
                                list(projects = as.list(as.character(projects))))
    }
  ))
}

# Normalize old addin field names and the versioned provider contract into a
# single server-side shape. Browser policy may hide selection text, while active
# file metadata remains available.
.normalize_ide_context <- function(context, selection_visible = TRUE) {
  if (is.null(context) || !is.list(context)) return(NULL)
  scalar_chr <- function(x) {
    if (is.null(x) || !length(x) || is.na(x[[1L]]) || !nzchar(as.character(x[[1L]]))) NULL
    else as.character(x[[1L]])
  }
  scalar_int <- function(x) {
    value <- suppressWarnings(as.integer(x %||% NA_integer_))
    if (!length(value) || is.na(value[[1L]])) NULL else value[[1L]]
  }
  active_file <- scalar_chr(context$active_file %||% context$activeFile %||% context$path)
  relative_path <- scalar_chr(context$relative_path %||% context$relativePath %||% context$rel)
  selection_text <- scalar_chr(context$selection_text %||% context$selectionText %||% context$selection)
  cursor_text <- scalar_chr(context$cursor_text %||% context$cursorText)
  if (!isTRUE(selection_visible)) { selection_text <- NULL; cursor_text <- NULL }  # 眼睛关 → 一并不发
  normalized <- list(
    active_file = active_file,
    relative_path = relative_path,
    selection_text = selection_text,
    start_line = scalar_int(context$start_line %||% context$startLine %||% context$first_line),
    end_line = scalar_int(context$end_line %||% context$endLine %||% context$last_line),
    cursor_text = cursor_text,
    cursor_line = scalar_int(context$cursor_line %||% context$cursorLine),
    cursor_start = scalar_int(context$cursor_start %||% context$cursorStart),
    cursor_end = scalar_int(context$cursor_end %||% context$cursorEnd),
    selection_visible = isTRUE(selection_visible),
    document_version = context$document_version %||% context$documentVersion
  )
  if (all(vapply(normalized[c("active_file", "relative_path", "selection_text")], is.null, logical(1))))
    return(NULL)
  normalized
}

.read_ide_context <- function(provider, selection_visible = TRUE) {
  if (!is.function(provider)) return(NULL)
  raw <- tryCatch(provider(), error = function(e) NULL)
  .normalize_ide_context(raw, selection_visible = selection_visible)
}

.ide_context_metadata <- function(context) {
  if (is.null(context)) return(NULL)
  text <- context$selection_text
  list(
    activeFile = context$active_file,
    relativePath = context$relative_path,
    startLine = context$start_line,
    endLine = context$end_line,
    hasSelection = !is.null(text) && nzchar(text),
    selectionChars = if (is.null(text)) 0L else nchar(text),
    selectionVisible = isTRUE(context$selection_visible),
    documentVersion = context$document_version
  )
}

# Run backend cleanup to completion even when RStudio's Viewer Stop has already
# queued a user interrupt. processx::process$wait() is interruptible, so merely
# catching `error` is insufficient (`interrupt` does not inherit from `error`).
.run_handler_cleanup <- function(cleanup) {
  if (!is.function(cleanup)) return(invisible(NULL))
  tryCatch(
    suspendInterrupts(cleanup()),
    interrupt = function(e) NULL,
    error = function(e) NULL
  )
  invisible(NULL)
}

# NULL-coalescing helper. Intentionally kept separate from the copy in
# handlers.R: the backend layer (handlers.R + ellmer_store.R) is designed to be
# extractable into a standalone package (see .claude/plans/02-runtime-extraction.md),
# so the widget layer keeps its own copy to stay self-sufficient post-split.
`%||%` <- function(x, y) if (is.null(x)) y else x
