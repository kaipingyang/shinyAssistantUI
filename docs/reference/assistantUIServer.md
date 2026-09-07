# Assistant UI Server Module

Handles the server-side logic for an `assistantUIOutput()` widget:
receives user messages, calls a backend handler, and streams responses
back to the UI.

## Usage

``` r
assistantUIServer(
  id,
  handler,
  show_thread_list = FALSE,
  persistence = c("client", "server", "none"),
  suggestions = list(),
  commands = list(),
  tools = list(),
  action_items = list(),
  ide_context_provider = NULL,
  workspace_search_provider = NULL,
  on_action = NULL,
  on_session_load = NULL,
  on_feedback = NULL,
  on_rename = NULL,
  on_open_file = NULL,
  on_run_in_console = NULL,
  on_edits = NULL,
  on_archive_session = NULL,
  on_delete_session = NULL,
  workspace_mode = FALSE,
  working_dir = NULL,
  git_branch = NULL,
  git_branch_provider = NULL,
  native_picker = FALSE,
  on_pick_working_dir = NULL,
  on_set_working_dir = NULL,
  projects = NULL,
  on_save_project = NULL,
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
  assistant_text_size = NULL,
  on_set_assistant_text_size = NULL,
  run_r_enabled = NULL,
  on_toggle_run_r = NULL,
  show_claude_edits_in_rstudio = NULL,
  on_toggle_claude_edits_in_rstudio = NULL,
  thread_max_width = NULL,
  show_usage = FALSE,
  context_window = NULL,
  usage_style = c("ring", "bar", "text"),
  latex = FALSE,
  code_theme = "one-light",
  strings = NULL,
  warming_label = NULL,
  welcome_message = NULL,
  assistant_avatar = list(fallback = "AI"),
  theme = NULL,
  dark_mode = FALSE,
  show_timestamps = FALSE,
  modal = FALSE,
  prewarm = FALSE,
  allow_warmup = TRUE,
  max_concurrent_runs = 1L
)
```

## Arguments

  - id:
    
    The module ID matching the `outputId` passed to
    `assistantUIOutput()`.

  - handler:
    
    A function with signature `function(message, thread_id, on_chunk,
    on_done, on_error, on_tool_call, on_tool_result, is_reload)` where:
    
      - `message` — character string of the user's message.
    
      - `thread_id` — character string identifying the current thread
        (for multi-turn conversation routing).
    
      - `on_chunk(text)` — call repeatedly to stream response tokens.
    
      - `on_done()` — call once when the response is complete.
    
      - `on_error(msg)` — call to surface an error in the UI.
    
      - `on_tool_call(tool_call_id, tool_name, args, annotations)` —
        show a tool call card. `args` should be a named list.
        `annotations` is an optional named list controlling card
        appearance and result rendering. Recognized keys:
        
          - `icon` — lucide icon name (`"search"`, `"database"`,
            `"code"`, …)
        
          - `title` — display name shown in the card header
        
          - `requiresApproval` — `TRUE` to show Approve/Deny buttons
        
          - `resultType` — how to render the result from
            `on_tool_result()`: `"auto"` (default, JSON/text in
            `<pre>`), `"markdown"`, `"table"`, `"code"`, `"image"`,
            `"file"`, `"html"`
        
          - `resultLang` — language for `resultType = "code"` (e.g.
            `"r"`, `"python"`, `"sql"`; default `"text"`)
        
          - `resultFilename` — filename for `resultType = "file"`
            download button (e.g. `"results.csv"`; default `"download"`)
    
      - `on_tool_result(tool_call_id, result, is_error = FALSE)` —
        update the tool card with the result.
        
          - `resultType = "table"`: pass `jsonlite::toJSON(df,
            auto_unbox = FALSE)`
        
          - `resultType = "file"`: pass base64 data URL
            (`paste0("data:text/csv;base64,",
            jsonlite::base64_enc(chartr(...)))`)
        
          - `resultType = "html"`: pass HTML string (rendered via
            `dangerouslySetInnerHTML`; only use with trusted tool
            output)
    
      - `attachments` — list of named lists, one per file the user
        attached. Each element has `type` (`"image"`, `"text"`, or
        `"file"`), `name` (filename), `data` (data-URL string for
        images, plain text for text files, base64 for other files), and
        optionally `contentType` (MIME type). Empty list `list()` when
        no attachments are present.
    
      - `is_reload` — `TRUE` when the user clicked "regenerate"; the
        handler receives the same `message` text and can remove the
        previous assistant turn from the LLM history before re-running.
    
      - `is_cancelled` — zero-argument function that returns `TRUE` once
        the user has clicked the stop button. Poll this inside your
        streaming loop to implement true server-side cancellation:
        
            for (chunk in stream) {
              if (is_cancelled()) break
              on_chunk(chunk)
            }
            on_done()
        
        For
        [ClaudeAgentSDK](https://github.com/kaipingyang/ClaudeAgentSDK),
        call `client$interrupt()` when `is_cancelled()` returns `TRUE`.
    
      - `wait_for_approval` — `function(tool_call_id)` that returns a
        `promises::promise` which resolves to `TRUE` (approved) or
        `FALSE` (denied) once the user clicks Approve/Deny in the tool
        card UI. Use inside a `coro::async` `on_tool_request` callback
        to pause the stream until human approval:
        
            chat$on_tool_request(coro::async(function(request) {
              on_tool_call(request@id, request@name, request@arguments,
                          list(requiresApproval = TRUE))
              approved <- coro::await(wait_for_approval(request@id))
              if (!approved) ellmer::tool_reject("User denied the tool call.")
            }))
    
      - `register_cancel` — `function(fn)` that stores a cancel callback
        for the current thread. Call once before starting the stream
        with a function that performs true HTTP cancellation (e.g.
        `register_cancel(function() ctrl$cancel("Interrupted"))`). When
        the user clicks Stop, `assistantUIServer` calls `fn()`
        immediately so the in-flight HTTP request is closed rather than
        silently drained.
    
    All parameters except `message`, `on_chunk`, `on_done`, and
    `on_error` are optional: handlers that omit them continue to work
    unchanged.
    
    The handler may return a promise (from `promises` or `coro`) for
    async streaming; errors from the promise are automatically forwarded
    via `on_error`.

  - show\_thread\_list:
    
    Logical. If `TRUE`, a thread list sidebar is shown inside the widget
    for switching between conversations. Default `FALSE`
    (backward-compatible).

  - persistence:
    
    Where thread history is persisted. `"client"` (default) restores and
    synchronizes browser `localStorage`; `"server"` treats
    `send_sessions()` snapshots as authoritative and never accesses
    `localStorage`; `"none"` keeps state only for the current page
    lifetime and likewise never accesses `localStorage`.

  - suggestions:
    
    List of starter suggestion bubbles shown before the first message.
    Each element is a list with `prompt` (required, the text sent on
    click) and optional `text` (display label, defaults to `prompt`).

  - commands:
    
    List of slash-command definitions. Each element is a list with
    `name` (e.g. `"summarize"`), `description`, `prompt` (the message
    sent when the command is submitted), and optional `category` (group
    label shown as a section header, such as `"Personal Skills"` or
    `"Project Skills"`).

  - tools:
    
    List of tool definitions for the \\@ mention menu. Each element is a
    list with `name` and `description`. Typically mirrors the tools
    registered with ellmer.

  - action\_items:
    
    List of action-type slash-command items. Unlike `commands`, these do
    not send a message to the AI — instead, clicking them fires
    `on_action(id)` on the R side, allowing arbitrary server logic. Each
    element is a list with `section` (group label), `id` (unique string
    passed to `on_action`), optional `command` (the slash name shown and
    matched for exact direct input; defaults to `id`), `label`, and
    optional `description`. Example:
    
        action_items = list(
          list(section = "Model",   id = "thinking-on",  label = "Enable thinking"),
          list(section = "Support", id = "view-docs",    label = "View help docs",
               description = "Open documentation")
        )

  - ide\_context\_provider:
    
    Optional zero-argument function sampled for every new user
    submission. It may return active file/selection metadata; selection
    text remains on the R side and is never sent to the browser.

  - workspace\_search\_provider:
    
    Optional function accepting `query`, `kinds`, and `limit`, returning
    literal file/folder mention entries. Supplying it advertises the
    workspace mention capability.

  - on\_action:
    
    `function(id)` called when the user clicks an item from
    `action_items`. `id` is the string from the item definition. Use
    this to trigger server-side logic (e.g. toggle a setting, open a
    URL, call `clear()`). `NULL` (default) means no handler is
    registered.

  - on\_session\_load:
    
    Optional `function(session_id, thread_id, send_thread)` called when
    the frontend requests messages for a historical session thread.

  - on\_feedback:
    
    Optional `function(message_id, type)` called when the user clicks a
    positive or negative feedback button (`type` is `"positive"` or
    `"negative"`).

  - on\_rename:
    
    Optional `function(thread_id, title)` called when the user renames a
    thread in the sidebar. The new title is already persisted
    client-side (localStorage); use this to sync server-side session
    stores.

  - on\_open\_file:
    
    Optional `function(path, line = NULL)` called when the user clicks a
    file reference in a tool card, or after the assistant edits a file
    (the most recent successful edit of a run is revealed). The Claude
    addin wires this to `rstudioapi::navigateToFile()`; leave `NULL`
    (default) in browser contexts where no editor is available.

  - on\_run\_in\_console:
    
    Optional `function(code)` called when the user clicks "Run in
    Console" on an R code block. The Claude addin wires this to
    `rstudioapi::sendToConsole(code, execute = TRUE)` so the code runs
    in the user's live R session (visible, with their
    objects/packages/plots). When supplied, R code blocks show a run
    button. Leave `NULL` (default) outside RStudio.

  - on\_edits:
    
    Optional `function(edits)` called when the assistant proposes file
    edits (used by the addin to show edit markers). Returning exactly
    `FALSE` also suppresses the automatic reveal of the last edited
    file; metadata and chat diff payloads are unaffected.

  - on\_archive\_session:
    
    Optional `function(session_id, archived)` called when the user
    archives (`archived = TRUE`) or unarchives (`FALSE`) a session in
    the sidebar. Use it to persist a server-authoritative soft-hide list
    so archived sessions stay hidden across reopens (the Claude addin
    stores this per project).

  - on\_delete\_session:
    
    Optional `function(session_id)` called when the user confirms
    deleting a session. This is destructive: the Claude addin wires it
    to `ClaudeAgentSDK::delete_session()`, permanently removing the
    transcript from disk. The UI requires an explicit confirmation
    before invoking it.

  - workspace\_mode:
    
    Logical. When `TRUE`, enables project-aware thread metadata and
    navigation. Incoming requests may supply an optional `project`
    snapshot; handlers, history callbacks, and thread-aware providers
    receive it only when their formals declare `project` (or `...`),
    preserving existing callback signatures. Defaults to `FALSE`.

  - working\_dir:
    
    Optional initial working directory shown in the working-directory
    picker (addin).

  - git\_branch:
    
    Optional initial Git branch label shown below the composer. Use
    `NULL` for non-Git directories so no branch element is rendered.

  - git\_branch\_provider:
    
    Optional function accepting `project` and returning its current
    branch label, or `NULL` outside Git. It is sampled after run
    completion, error, and cancellation so the composer metadata stays
    current.

  - native\_picker:
    
    Logical; whether a native directory chooser is available (RStudio
    addin).

  - on\_pick\_working\_dir:
    
    Optional `function()` invoked to open the native working-directory
    picker.

  - on\_set\_working\_dir:
    
    Optional `function(path)` called when the working directory changes.

  - projects:
    
    Optional character vector of saved working-directory favorites.

  - on\_save\_project:
    
    Optional `function()` to save the current directory as a favorite.

  - on\_remove\_project:
    
    Optional `function(path)` to remove a saved favorite.

  - files\_pane\_follow:
    
    Optional logical initial state of the "Files pane follows working
    dir" toggle (`NULL` hides it).

  - on\_toggle\_files\_pane\_follow:
    
    Optional `function(value)` called when that toggle changes.

  - auto\_run:
    
    Optional logical initial state of the auto-approve `run_r` toggle
    (`NULL` hides it).

  - on\_toggle\_auto\_run:
    
    Optional `function(value)` called when the auto-run toggle changes.

  - default\_permission\_mode:
    
    Optional character; default permission mode for new conversations
    (addin preference, persisted).

  - on\_set\_default\_permission\_mode:
    
    Optional `function(mode)` called when the default-mode preference
    changes.

  - mode\_visibility:
    
    Optional named list `list(showBypass=, showYolo=)` controlling which
    risky modes appear in the mode selector.

  - on\_set\_mode\_visibility:
    
    Optional `function(value)` called when mode visibility changes.

  - composer\_density:
    
    Optional character `"comfortable"` (default) or `"compact"` composer
    height preset.

  - on\_set\_composer\_density:
    
    Optional `function(value)` called when the composer height preset
    changes.

  - assistant\_text\_size:
    
    Optional character `"small"`, `"compact"` (Medium), or `"medium"`
    (Default) assistant response/tool text-size preset. The legacy value
    `"large"` is accepted and normalized to Default.

  - on\_set\_assistant\_text\_size:
    
    Optional `function(value)` called when the assistant response
    text-size preset changes.

  - run\_r\_enabled:
    
    Optional logical initial state of the `run_r` MCP tool toggle
    (`NULL` hides it).

  - on\_toggle\_run\_r:
    
    Optional `function(value)` called when the `run_r` toggle changes.

  - show\_claude\_edits\_in\_rstudio:
    
    Optional logical initial state of the addin's RStudio
    edit-presentation toggle (`NULL` hides it). When disabled, the addin
    neither publishes edit markers nor automatically reveals edited
    files.

  - on\_toggle\_claude\_edits\_in\_rstudio:
    
    Optional `function(value)` called when the RStudio edit-presentation
    toggle changes.

  - thread\_max\_width:
    
    Optional CSS length capping the chat content width (e.g. `"44rem"`,
    `"800px"`). Default `NULL` = **full width** (fills the pane, like
    the Claude Code CLI / VS Code). Pass a length to center the
    conversation in a fixed-width column (assistant-ui's classic
    readable layout). Applies to messages, composer and the
    pinned-question bar together.

  - show\_usage:
    
    Logical (default `FALSE`); show the token-usage indicator.

  - context\_window:
    
    Optional integer context-window size for the usage indicator.

  - usage\_style:
    
    Character; usage indicator style, one of `"ring"`, `"bar"`,
    `"text"`.

  - latex:
    
    Logical (default `FALSE`); enable KaTeX math rendering.

  - code\_theme:
    
    Character string selecting the syntax-highlighting theme for code
    blocks. Available light themes: `"one-light"` (default),
    `"ghcolors"`, `"vs"`, `"solarized-light"`. Available dark themes:
    `"vsc-dark-plus"`, `"dracula"`, `"nord"`, `"night-owl"`,
    `"one-dark"`.

  - strings:
    
    Optional named list for overriding UI text (tooltips, labels,
    placeholders). `NULL` (default) keeps all built-in English strings.
    Example for a customized UI:
    
        strings = list(
          assistantMessage = list(
            copy   = list(tooltip = "Copy text"),
            reload = list(tooltip = "Regenerate answer")
          ),
          editComposer = list(
            send   = list(label = "Send now"),
            cancel = list(label = "Cancel")
          )
        )

  - warming\_label:
    
    Optional character; cold-start indicator text (English). Defaults to
    a generic "Starting…". e.g. "Starting codeagent…".

  - welcome\_message:
    
    Optional character; empty-state greeting. Defaults to "How can I
    help you today?".

  - assistant\_avatar:
    
    Named list controlling the assistant's avatar. Fields: `fallback`
    (1–2 character string or emoji shown when no image is set), `src`
    (URL to an image), `alt` (alt text). Defaults to `list(fallback =
    "AI")`. Example with custom image:
    
        assistant_avatar = list(src = "https://example.com/logo.png", fallback = "AI")

  - theme:
    
    Optional named list of theme tokens to recolor the widget, e.g.\#'
    from `assistant_theme()`. Colors may be hex/named/`rgb()` strings
    and are converted to assistant-ui's HSL-component format. Applied as
    scoped CSS variables on this widget only (multiple widgets can have
    different themes). Example: `theme = assistant_theme(primary =
    "#2563eb")`.

  - dark\_mode:
    
    Dark color scheme control: `FALSE` (light, default), `TRUE` (dark),
    or `"auto"` (follow the OS/browser `prefers-color-scheme`). A custom
    `theme` overrides individual tokens in either mode.

  - show\_timestamps:
    
    Logical. If `TRUE`, each user/assistant message shows its send time
    (HH:MM), derived from the message id. Defaults to `FALSE`.
    
      - `on_session_load` — `function(session_id, thread_id,
        send_thread)` called when the frontend requests historical
        messages for a session thread. Used with `send_sessions()` (in
        the return value) to populate the sidebar with Claude Code
        sessions and lazy-load their messages on click.
        
          - `session_id` — the Claude session UUID
        
          - `thread_id` — the UI thread ID (equals `session_id` for
            imported threads)
        
          - `send_thread(messages)` — call with a list of
            `ThreadMessageLike` objects (each a named list with `id`,
            `role`, `content` fields) to populate the thread.

  - modal:
    
    Logical. If `TRUE`, renders the chat as a floating modal bubble
    instead of an inline panel.

  - prewarm:
    
    Logical (default `FALSE`). If `TRUE` and the `handler` exposes a
    `warmup` attribute (e.g. `make_claude_handler()`), pre-connect the
    initial thread's client on mount so the **first** message on that
    thread isn't slowed by the cold start (ClaudeSDKClient spawning the
    `claude` CLI subprocess). Historical session browsing is
    transcript-only and never enters the warmup queue; the first
    explicit send on a historical thread lazily connects and resumes its
    saved backend session. A brief cold-start indicator is shown while
    connecting. Newly created blank threads remain lazy unless they are
    the initial thread covered by this one-shot option. **Left `FALSE`
    by default on purpose**: enabling it makes app startup attempt a
    backend connection at mount, so a slow/unreachable backend would
    stall the open (the default lazy connect only happens on the first
    message). Turn on only when the backend is reliably available at
    load.

  - allow\_warmup:
    
    Logical (default `TRUE`); allow per-thread cold-start warmup of the
    handler. Warmups are deduplicated, limited to one at a time,
    deferred while any foreground run is active or queued, and cancelled
    when the Shiny session ends. The backend connect itself may still be
    synchronous.

  - max\_concurrent\_runs:
    
    Positive integer global limit for runs in different threads (default
    `1`, clamped to `8`). The requested limit is honored only when
    `handler` explicitly declares `attr(handler,
    "supports_concurrent_threads") <- TRUE`; all other handlers remain
    globally serial for backward compatibility. Invocations within one
    thread are always strict FIFO and never overlap.

## Value

A list with a `clear()` function that creates a new thread in the UI,
`send_tool_call()` / `send_tool_result()` for manual tool card control,
and `send_sessions(sessions)` for injecting a list of historical session
stubs into the sidebar (each element: named list with `id`, `title`,
`preview`, `createdAt` fields).
