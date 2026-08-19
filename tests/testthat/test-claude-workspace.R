test_that("workspace project router canonicalizes and isolates thread ownership", {
  one <- withr::local_tempdir()
  two <- withr::local_tempdir()
  missing <- file.path(tempdir(), "workspace-missing-project")

  router <- .new_workspace_project_router(
    c(one, file.path(one, "."), two, missing),
    initial = one
  )

  expect_identical(router$projects(), c(normalizePath(one), normalizePath(two), missing))
  expect_identical(router$current(), normalizePath(one))
  expect_true(router$bind("thread-one", one))
  expect_true(router$bind("thread-two", two))
  expect_identical(router$project_for("thread-one"), normalizePath(one))
  expect_identical(router$project_for("thread-two"), normalizePath(two))

  router$select(two)
  expect_identical(router$current(), normalizePath(two))
  expect_identical(router$project_for("new-thread"), normalizePath(two))
  expect_identical(router$project_for("thread-one"), normalizePath(one))
})

test_that("workspace snapshot annotates sessions with their owning project", {
  one <- withr::local_tempdir()
  two <- withr::local_tempdir()
  fake_list <- function(directory, archived_ids = character()) {
    id <- if (identical(directory, normalizePath(one))) "session-one" else "session-two"
    list(list(id = id, title = basename(directory), preview = "", createdAt = NULL,
              archived = id %in% archived_ids))
  }

  snapshot <- .workspace_session_snapshot(
    c(one, two),
    archived_path = tempfile(fileext = ".rds"),
    list_sessions = fake_list
  )

  expect_identical(vapply(snapshot, `[[`, character(1), "id"), c("session-one", "session-two"))
  expect_identical(
    vapply(snapshot, `[[`, character(1), "project"),
    c(normalizePath(one), normalizePath(two))
  )
  expect_identical(vapply(snapshot, `[[`, character(1), "projectLabel"), c(basename(one), basename(two)))
})

test_that("assistant server snapshots project into the handler invocation", {
  calls <- list()
  handler <- function(message, thread_id, project, on_done, ...) {
    calls[[length(calls) + 1L]] <<- list(message = message, thread = thread_id, project = project)
    on_done()
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 4L)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "from project one", threadId = "thread-one", runId = "run-one",
      project = "/tmp/project-one"
    ))
    session$flushReact()
    for (i in seq_len(10)) {
      later::run_now(0.05)
      session$flushReact()
      if (length(calls)) break
    }
    expect_length(calls, 1L)
    expect_identical(calls[[1L]]$project, "/tmp/project-one")
  })
})

test_that("thread-aware providers remain backward compatible", {
  expect_identical(
    .call_thread_provider(function() "legacy", "thread-a", "/tmp/a"),
    "legacy"
  )
  expect_identical(
    .call_thread_provider(function(thread_id, project) paste(thread_id, project),
                          "thread-a", "/tmp/a"),
    "thread-a /tmp/a"
  )
})

test_that("Claude Workspace is registered as a second addin", {
  dcf <- read.dcf(system.file("rstudio", "addins.dcf", package = "shinyAssistantUI"), all = TRUE)
  expect_true("Claude Code Chat" %in% dcf[, "Name"])
  expect_true("Claude Workspace" %in% dcf[, "Name"])
  expect_true("claude_workspace_addin" %in% dcf[, "Binding"])
})


test_that("assistant server forwards project to project-aware callbacks only", {
  handler_calls <- list()
  history_calls <- list()
  search_calls <- list()
  rename_calls <- list()
  handler <- function(message, thread_id, project, on_done, ...) {
    handler_calls[[length(handler_calls) + 1L]] <<- list(
      thread_id = thread_id, project = project
    )
    on_done()
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      workspace_mode = TRUE,
      ide_context_provider = function(thread_id, project) {
        list(rel = paste0(basename(project), ".R"))
      },
      workspace_search_provider = function(query, thread_id, project) {
        search_calls[[length(search_calls) + 1L]] <<- list(
          query = query, thread_id = thread_id, project = project
        )
        list()
      },
      on_session_load = function(session_id, thread_id, project, send_thread) {
        history_calls[[length(history_calls) + 1L]] <<- list(
          session_id = session_id, thread_id = thread_id, project = project
        )
        send_thread(list())
      },
      on_rename = function(thread_id, title, project) {
        rename_calls[[length(rename_calls) + 1L]] <<- list(
          thread_id = thread_id, title = title, project = project
        )
      },
      max_concurrent_runs = 4L
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input_workspace_search = list(
      requestId = "search-1", threadId = "thread-a", query = "app",
      project = "/tmp/project-a"
    ))
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "session-a", threadId = "thread-a",
      requestId = "history-1", project = "/tmp/project-a"
    ))
    session$setInputs(chat_input_rename = list(
      threadId = "thread-a", title = "Renamed", project = "/tmp/project-a"
    ))
    session$flushReact()

    session$setInputs(chat_input = list(
      text = "hello", threadId = "thread-a", runId = "run-a",
      project = "/tmp/project-a"
    ))
    session$flushReact()
    for (i in seq_len(10)) {
      later::run_now(0.05)
      session$flushReact()
      if (length(handler_calls)) break
    }

    expect_identical(search_calls[[1L]]$project, "/tmp/project-a")
    expect_identical(history_calls[[1L]]$project, "/tmp/project-a")
    expect_identical(rename_calls[[1L]]$project, "/tmp/project-a")
    expect_identical(handler_calls[[1L]]$project, "/tmp/project-a")
  })
})

test_that("chat app keeps ordinary defaults and enables workspace defaults", {
  skip_if_not_installed("ClaudeAgentSDK")
  withr::local_envvar(HOME = withr::local_tempdir())
  project <- withr::local_tempdir()
  other <- withr::local_tempdir()
  captured <- list()
  sent_sessions <- list()

  local_mocked_bindings(
    make_claude_handler = function(options, cwd_provider = NULL, models = NULL,
                                   session_map_path) {
      fn <- function(message, on_done = NULL, ...) {
        if (is.function(on_done)) on_done()
      }
      attr(fn, "supports_concurrent_threads") <- TRUE
      fn
    },
    load_claude_skills = function(project_dir) list(),
    make_claude_session_loader = function(session_map_path) function(...) NULL,
    list_claude_sessions = function(directory, limit = 100L,
                                    archived_ids = character()) list(),
    assistantUIServer = function(...) {
      captured[[length(captured) + 1L]] <<- list(...)
      list(
        send_sessions = function(payload) {
          sent_sessions[[length(sent_sessions) + 1L]] <<- payload
        },
        send_commands = function(...) NULL,
        send_working_dir = function(...) NULL,
        send_projects = function(...) NULL
      )
    }
  )

  ordinary <- .claude_chat_app(project, options = list())
  shiny::testServer(ordinary$serverFuncSource(), session$flushReact())
  workspace <- .claude_chat_app(
    project, options = list(), workspace = TRUE,
    workspace_projects = other
  )
  shiny::testServer(workspace$serverFuncSource(), session$flushReact())

  expect_false(captured[[1L]]$workspace_mode)
  expect_identical(captured[[1L]]$max_concurrent_runs, 2L)
  expect_true(captured[[2L]]$workspace_mode)
  expect_identical(captured[[2L]]$max_concurrent_runs, 4L)
  # `projects` is the explicit persisted Favorites payload, not the session-local
  # Workspace registry. A fresh HOME has no favorites even though A/B are registered.
  expect_identical(captured[[2L]]$projects, character())
  workspace_payloads <- Filter(
    function(payload) !is.null(payload$projectOrder),
    sent_sessions
  )
  expect_length(workspace_payloads, 1L)
  expect_identical(
    unlist(workspace_payloads[[1L]]$projectOrder, use.names = FALSE),
    normalizePath(c(project, other), winslash = "/")
  )
})

test_that("selecting a new Workspace project prepends it without reordering existing projects", {
  one <- withr::local_tempdir()
  two <- withr::local_tempdir()
  three <- withr::local_tempdir()
  router <- .new_workspace_project_router(c(one, two), initial = one)

  router$select(three)
  expected <- normalizePath(c(three, one, two), winslash = "/")
  expect_identical(router$projects(), expected)
  expect_identical(router$current(), expected[[1L]])

  # Selecting an already-registered project updates current without making the
  # folder tree jump on every history click.
  router$select(two)
  expect_identical(router$projects(), expected)
  expect_identical(router$current(), normalizePath(two, winslash = "/"))
})

test_that("background job preserves workspace spec and display name", {
  seen <- new.env(parent = emptyenv())
  spec <- list(
    project = "/workspace/one",
    workspace = TRUE,
    workspace_projects = c("/workspace/one", "/workspace/two"),
    job_name = "Claude Workspace"
  )
  result <- .run_claude_bg_job(
    spec,
    port = 4322L,
    job_run = function(path, name, workingDir) {
      seen$name <- name
      seen$working_dir <- workingDir
    },
    show_viewer = function(...) NULL,
    wait_ready = function(...) FALSE
  )

  roundtrip <- readRDS(result$spec_path)
  expect_true(roundtrip$workspace)
  expect_identical(roundtrip$workspace_projects, spec$workspace_projects)
  expect_identical(seen$name, "Claude Workspace")
  expect_identical(seen$working_dir, spec$project)
})


test_that("Claude handler resolves cwd from the submitted thread project", {
  skip_if_not_installed("ClaudeAgentSDK")
  received <- NULL
  provider_call <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() list()
  client$get_server_info <- function() list()

  local_mocked_bindings(
    .new_claude_client = function(options) {
      received <<- options
      client
    },
    .claude_drain_timeout_seconds = function() 0
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    cwd_provider = function(thread_id, project) {
      provider_call <<- list(thread_id = thread_id, project = project)
      project
    },
    session_map_path = tempfile(fileext = ".rds")
  )

  finished <- FALSE
  handler(
    message = "route me",
    thread_id = "thread-project-a",
    project = "/tmp/project-a",
    attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) finished <<- TRUE,
    on_error = function(...) finished <<- TRUE,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() TRUE,
    wait_for_approval = function(...) {
      promises::promise_resolve(list(approved = FALSE))
    }
  )
  for (i in seq_len(20L)) {
    later::run_now()
    if (isTRUE(finished)) break
  }

  expect_identical(provider_call, list(
    thread_id = "thread-project-a", project = "/tmp/project-a"
  ))
  expect_identical(received$cwd, "/tmp/project-a")
  expect_true(finished)
})

test_that("background job forwards workspace fields to the shared app", {
  spec_path <- tempfile(fileext = ".rds")
  saveRDS(list(
    project = "/workspace/one",
    workspace = TRUE,
    workspace_projects = c("/workspace/one", "/workspace/two")
  ), spec_path)
  captured <- NULL

  local_mocked_bindings(
    .claude_chat_app = function(project, workspace, workspace_projects, ...) {
      captured <<- list(
        project = project,
        workspace = workspace,
        workspace_projects = workspace_projects
      )
      "WORKSPACE_APP"
    }
  )
  local_mocked_bindings(
    runApp = function(app, port, host, launch.browser) "RAN",
    .package = "shiny"
  )

  .claude_run_in_job(spec_path, port = 6010L)
  expect_identical(captured, list(
    project = "/workspace/one",
    workspace = TRUE,
    workspace_projects = c("/workspace/one", "/workspace/two")
  ))
})


test_that("explicit project snapshots correct an earlier implicit router choice", {
  one <- withr::local_tempdir()
  two <- withr::local_tempdir()
  router <- .new_workspace_project_router(c(one, two), initial = one)

  expect_identical(router$project_for("thread-a"), normalizePath(one))
  expect_identical(router$project_for("thread-a", two), normalizePath(two))
  expect_identical(router$project_for("thread-a"), normalizePath(two))
})

test_that("compatible callbacks preserve legacy positional prefixes", {
  expect_identical(
    .call_compatible_callback(
      function(id, value) paste(id, value),
      list(session_id = "session-a", archived = TRUE, project = "/work/a")
    ),
    "session-a TRUE"
  )
  expect_identical(
    .call_compatible_callback(
      function(p, l = NULL) paste(p, l),
      list(path = "R/app.R", line = 12L, thread_id = "thread-a", project = "/work/a")
    ),
    "R/app.R 12"
  )
  expect_identical(
    .call_compatible_callback(
      function(project) project,
      list(thread_id = "thread-a", project = "/work/a")
    ),
    "/work/a"
  )
})

test_that("warmup snapshots the thread project before delayed execution", {
  warmups <- list()
  handler <- function(message, on_done, ...) on_done()
  attr(handler, "warmup") <- function(thread_id, project = NULL) {
    warmups[[length(warmups) + 1L]] <<- list(thread_id = thread_id, project = project)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, prewarm = TRUE)
  }, {
    session$flushReact()
    session$setInputs(chat_input_warmup = list(
      threadId = "thread-a", project = "/work/a"
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now(0.1)
      session$flushReact()
      if (length(warmups)) break
    }
    expect_identical(warmups, list(list(
      thread_id = "thread-a", project = "/work/a"
    )))
  })
})


test_that("Workspace startup order prioritizes current then recent project activity", {
  root <- withr::local_tempdir()
  current <- file.path(root, "current")
  recent <- file.path(root, "recent")
  older <- file.path(root, "older")
  project_10 <- file.path(root, "project-10")
  project_2 <- file.path(root, "project-2")
  same_a <- file.path(root, "a", "same")
  same_z <- file.path(root, "z", "same")
  invisible(vapply(
    c(current, recent, older, project_10, project_2, same_a, same_z),
    dir.create,
    logical(1),
    recursive = TRUE
  ))
  recent_seconds <- as.numeric(as.POSIXct("2026-08-16 12:00:00", tz = "UTC"))
  sessions <- list(
    list(id = "older", project = older, createdAt = "2026-08-15T12:00:00Z"),
    list(id = "recent-old", project = recent, createdAt = recent_seconds * 1000),
    list(id = "recent-new", project = recent, createdAt = recent_seconds),
    list(id = "invalid", project = project_10, createdAt = "not-a-time")
  )

  ordered <- .workspace_project_activity_order(
    c(project_10, same_z, older, current, project_2, recent, same_a),
    sessions,
    current = current
  )

  expect_identical(
    ordered,
    normalizePath(
      c(current, recent, older, project_2, project_10, same_a, same_z),
      winslash = "/"
    )
  )
})

test_that("Workspace freezes startup order while new projects still prepend", {
  one <- withr::local_tempdir()
  two <- withr::local_tempdir()
  three <- withr::local_tempdir()
  router <- .new_workspace_project_router(c(one, two), initial = one)

  router$reorder(c(two, one))
  expected <- normalizePath(c(two, one), winslash = "/")
  expect_identical(router$projects(), expected)

  router$select(one)
  expect_identical(router$projects(), expected)

  router$select(three)
  expect_identical(
    router$projects(),
    normalizePath(c(three, two, one), winslash = "/")
  )
})
