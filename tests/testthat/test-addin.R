test_that(".rel_path strips the project prefix and keeps outside paths absolute", {
  expect_equal(.rel_path("/proj/R/foo.R", "/proj"), "R/foo.R")
  expect_equal(.rel_path("/proj/sub/dir/x.R", "/proj"), "sub/dir/x.R")
  # path outside the project stays absolute (normalized)
  expect_equal(.rel_path("/other/x.R", "/proj"), "/other/x.R")
  # empty / NULL are passed through
  expect_equal(.rel_path("", "/proj"), "")
  expect_null(.rel_path(NULL, "/proj"))
})

test_that(".addin_context_text embeds project, file and selection", {
  ctx <- list(rel = "R/foo.R", selection = "x <- 1", first_line = 3, last_line = 5)
  txt <- .addin_context_text(ctx, "/proj")
  expect_true(grepl("/proj", txt, fixed = TRUE))
  expect_true(grepl("R/foo.R", txt, fixed = TRUE))
  expect_true(grepl("x <- 1", txt, fixed = TRUE))
  expect_true(grepl("lines 3-5", txt, fixed = TRUE))
})

test_that(".addin_context_text truncates a huge selection", {
  ctx <- list(rel = "a.R", selection = strrep("a", 5000L), first_line = 1, last_line = 1)
  txt <- .addin_context_text(ctx, "/p")
  expect_true(grepl("truncated", txt, fixed = TRUE))
  expect_lt(nchar(txt), 4400L)
})

test_that(".addin_context_text with NULL ctx is project-only", {
  txt <- .addin_context_text(NULL, "/proj")
  expect_true(grepl("/proj", txt, fixed = TRUE))
  expect_false(grepl("active editor file", txt, fixed = TRUE))
})

test_that(".addin_project falls back to getwd() without rstudioapi", {
  # No RStudio in test env -> getwd()
  expect_identical(.addin_project(), getwd())
})

test_that(".addin_editor_context returns NULL when not in RStudio", {
  expect_null(.addin_editor_context("/proj"))
})

test_that(".claude_chat_app builds a shiny app (no connection at build time)", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  app <- .claude_chat_app(tempdir(), ctx = NULL, permission_mode = "default", prewarm = FALSE)
  on.exit(attr(app, "shinyAssistantUI_cleanup")(), add = TRUE)
  expect_s3_class(app, "shiny.appobj")
})

test_that(".claude_chat_app injects project sessions into the sidebar", {
  skip_if_not_installed("ClaudeAgentSDK")

  project <- normalizePath(tempdir(), mustWork = TRUE)
  listed_directory <- NULL
  listed_limit <- "not-called"
  sent_sessions <- list()
  server_args <- NULL
  normal_stop_calls <- 0L
  expected <- lapply(seq_len(140L), function(i) list(
    id = sprintf("history-%03d", i), title = paste("Historical session", i),
    preview = paste("Preview", i), createdAt = i, archived = identical(i, 140L)
  ))

  local_mocked_bindings(
    make_claude_handler = function(options, cwd_provider = NULL, models = NULL, session_map_path) function(...) NULL,
    load_claude_skills = function(project_dir) list(),
    make_claude_session_loader = function(session_map_path) function(...) NULL,
    .stop_claude_gadget_normally = function() {
      normal_stop_calls <<- normal_stop_calls + 1L
      invisible(NULL)
    },
    list_claude_sessions = function(directory, limit = 100L, archived_ids = character()) {
      listed_directory <<- directory
      listed_limit <<- limit
      if (is.null(limit)) expected else utils::head(expected, limit)
    },
    assistantUIServer = function(...) {
      server_args <<- list(...)
      list(send_sessions = function(sessions) {
        sent_sessions[[length(sent_sessions) + 1L]] <<- sessions
      })
    }
  )

  app <- .claude_chat_app(project, options = list(), prewarm = FALSE)
  on.exit(attr(app, "shinyAssistantUI_cleanup")(), add = TRUE)
  shiny::testServer(app$serverFuncSource(), {
    session$flushReact()
    expect_null(listed_directory)
    expect_length(sent_sessions, 0L)

    session$setInputs(chat_input_sessions_ready = list(ts = 1))
    session$flushReact()
    session$setInputs(cancel = 1L)
    session$flushReact()
  })

  expect_identical(normal_stop_calls, 1L)
  expect_identical(listed_directory, project)
  expect_null(listed_limit)
  expect_length(sent_sessions, 1L)
  expect_identical(sent_sessions[[1L]], list(sessions = expected))
  expect_identical(server_args$persistence, "server")
  action_commands <- vapply(server_args$action_items, `[[`, character(1), "command")
  expect_setequal(action_commands, c("context", "compact", "clear", "mcp", "model"))
})

test_that(".claude_chat_ui fills the page without Bootstrap", {
  ui <- .claude_chat_ui()
  dependencies <- htmltools::findDependencies(ui)
  dependency_names <- vapply(dependencies, `[[`, character(1), "name")
  rendered_tags <- htmltools::renderTags(ui)
  rendered <- paste0(rendered_tags$head, rendered_tags$html)

  bootstrap <- Filter(function(x) identical(x$name, "bootstrap"), dependencies)
  expect_length(bootstrap, 1L)
  expect_identical(bootstrap[[1L]]$version, "9999")
  expect_true("htmltools-fill" %in% dependency_names)
  expect_match(rendered, 'id="chat"', fixed = TRUE)
  expect_match(rendered, 'rel="icon"', fixed = TRUE)
  expect_match(rendered, 'href="data:,"', fixed = TRUE)
  expect_match(rendered, "height:100%", fixed = TRUE)
  expect_false(grepl(".shiny-html-output", rendered, fixed = TRUE))
})


test_that("workspace index includes gitignored files (Option 1), derives folders, excludes noise dirs", {
  skip_if(Sys.which("git") == "", "git is required")
  project <- tempfile("workspace-")
  dir.create(project)
  dir.create(file.path(project, "R"))
  dir.create(file.path(project, "nested", "deep"), recursive = TRUE)
  dir.create(file.path(project, "node_modules"))
  writeLines("ignored.txt", file.path(project, ".gitignore"))
  writeLines("x <- 1", file.path(project, "R", "app.R"))
  writeLines("visible", file.path(project, "nested", "deep", "note.txt"))
  writeLines("secret", file.path(project, "ignored.txt"))
  writeLines("pkg", file.path(project, "node_modules", "pkg.js"))
  system2("git", c("-C", shQuote(project), "init", "--quiet"))

  index <- .addin_workspace_index(project)
  files <- vapply(Filter(function(x) identical(x$kind, "file"), index), `[[`, character(1), "path")
  folders <- vapply(Filter(function(x) identical(x$kind, "folder"), index), `[[`, character(1), "path")

  # Option 1：被 gitignore 的 ignored.txt 现在也包含。
  expect_true(all(c("R/app.R", "nested/deep/note.txt", ".gitignore", "ignored.txt") %in% files))
  expect_false(any(grepl("node_modules", files)))   # 噪声目录仍排除
  expect_true(all(c("R/", "nested/", "nested/deep/") %in% folders))
})

test_that("workspace search is fuzzy, deterministic, and keeps literal paths", {
  index <- list(
    list(kind = "file", path = "src/components/AssistantUI.tsx"),
    list(kind = "file", path = "R/assistant_utils.R"),
    list(kind = "folder", path = "src/components/")
  )
  found <- .addin_workspace_search(index, "aui", kinds = c("file", "folder"), limit = 10L)
  expect_identical(vapply(found, `[[`, character(1), "path"),
                   c("R/assistant_utils.R", "src/components/AssistantUI.tsx"))
  expect_identical(found[[1L]]$insertText, "@R/assistant_utils.R")
  expect_identical(.addin_workspace_search(index, "components", limit = 1L)[[1L]]$kind,
                   "folder")
})

test_that("Claude addin wires live IDE context and workspace providers", {
  skip_if_not_installed("ClaudeAgentSDK")
  server_args <- NULL
  local_mocked_bindings(
    make_claude_handler = function(options, cwd_provider = NULL, models = NULL, session_map_path) {
      function(message, on_chunk = NULL) "ok"
    },
    load_claude_skills = function(project_dir) list(),
    make_claude_session_loader = function(session_map_path) function(...) NULL,
    list_claude_sessions = function(directory, limit = 100L) list(),
    assistantUIServer = function(...) {
      server_args <<- list(...)
      list(send_sessions = function(...) NULL)
    }
  )

  app <- .claude_chat_app(tempdir(), ctx = list(rel = "stale.R", selection = "old"),
                          options = list(), prewarm = FALSE)
  on.exit(attr(app, "shinyAssistantUI_cleanup")(), add = TRUE)
  shiny::testServer(app$serverFuncSource(), session$flushReact())

  expect_true(is.function(server_args$ide_context_provider))
  expect_true(is.function(server_args$workspace_search_provider))
  expect_no_error(server_args$handler(
    message = "hello",
    on_chunk = function(...) NULL,
    on_source = function(...) NULL,
    is_reload = FALSE,
    register_cancel = function(...) NULL
  ))
})


test_that("Background Job memory guard exposes the addin monitor without diagnostics", {
  skip_if_not_installed("ClaudeAgentSDK")
  server_args <- NULL
  memory_observer <- NULL
  sent <- list()
  local_mocked_bindings(
    make_claude_handler = function(options, cwd_provider = NULL, models = NULL,
                                   session_map_path, memory_guard_config = NULL,
                                   on_memory_observation = NULL) {
      memory_observer <<- on_memory_observation
      function(...) NULL
    },
    load_claude_skills = function(project_dir) list(),
    make_claude_session_loader = function(session_map_path) function(...) NULL,
    list_claude_sessions = function(...) list(),
    assistantUIServer = function(...) {
      server_args <<- list(...)
      list(send_sessions = function(...) NULL)
    }
  )

  app <- .claude_chat_app(
    tempdir(), options = list(), prewarm = FALSE,
    memory_guard_config = .memory_guard_default_config(),
    diagnostics = NULL
  )
  on.exit(attr(app, "shinyAssistantUI_cleanup")(), add = TRUE)
  shiny::testServer(app$serverFuncSource(), {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    expect_true(is.function(memory_observer))
    addon <- attr(server_args$handler, "ui_addons")$memoryMonitor
    expect_identical(addon$version, 4L)
    expect_named(addon, c("version", "ownerSeed", "lastRevision"))
    expect_gt(addon$ownerSeed, 0)
    expect_null(server_args$diagnostics)

    memory_observer(
      list(pss_bytes = 80, rss_bytes = 90, prompt = "PROMPT-SENTINEL"),
      "normal", "normal"
    )
    expect_length(sent, 0L)
    session$setInputs(chat_input_memory_monitor_visible = list(
      version = 2L, ownerId = addon$ownerSeed, openId = 1,
      visible = TRUE, revision = 0, sample = NULL
    ))
    session$flushReact()
    expect_length(sent, 1L)
    expect_identical(sent[[1L]]$type, "chat_input:memory-monitor-sample")
    expect_named(sent[[1L]]$message, c(
      "version", "ownerId", "openId", "revision", "sample"
    ))

    settings_addon <- attr(server_args$handler, "ui_addons")$diagnosticsSettings
    expect_named(settings_addon, c("version", "kind", "ownerSeed", "ownerId", "fields"))
    expect_identical(settings_addon$version, 2L)
    expect_identical(settings_addon$kind, "settings_bind")
    expect_identical(settings_addon$ownerSeed, settings_addon$ownerId)
    expect_named(settings_addon$fields, shinyAssistantUI:::.addin_settings_fields())
    expect_true(all(vapply(settings_addon$fields, function(field) {
      identical(names(field), c("value", "revision"))
    }, logical(1))))
    launch_addon <- attr(server_args$handler, "ui_addons")$diagnosticsLaunch
    expect_named(launch_addon, c(
      "version", "launchEnabled", "environmentOverride", "launchKind", "writerStartup"
    ))
    expect_identical(launch_addon$version, 2L)
    expect_true(is.logical(launch_addon$launchEnabled) && length(launch_addon$launchEnabled) == 1L)
    expect_true(launch_addon$environmentOverride %in% c("none", "on", "off"))
    expect_true(launch_addon$launchKind %in% c("job", "foreground"))
    expect_true(launch_addon$writerStartup %in% c("pending", "started", "off", "failed"))
    expect_null(attr(server_args$handler, "ui_addons")$settings)
    expect_null(attr(server_args$handler, "ui_addons")$performanceOrb)
    expect_named(sent[[1L]]$message$sample, c(
      "state", "pssBytes", "rssBytes", "treeRssBytes", "treeProcessCount",
      "cgroupCurrentBytes", "cgroupMaxBytes",
      "cgroupLimited", "softPssBytes", "hardPssBytes", "softRssBytes", "hardRssBytes"
    ))
    expect_false(grepl("PROMPT-SENTINEL", paste(capture.output(str(sent)), collapse = "")))
  })
})
