# 任务 D：只揭示最近一次成功编辑的文件（run 结束时 flush 一次）
test_that(".new_edit_reveal_tracker 只在 run 结束返回最近一次成功编辑", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()

  tracker$note_call("t1", "Edit", list(file_path = "R/a.R"))
  tracker$note_result("t1", is_error = FALSE)
  tracker$note_call("t2", "Write", list(file_path = "R/b.R"))
  tracker$note_result("t2", is_error = FALSE)

  # 多个成功编辑 → flush 只返回最近一次
  expect_identical(tracker$flush(), "R/b.R")
  # flush 后清空
  expect_null(tracker$flush())
})

test_that(".new_edit_reveal_tracker 忽略非编辑工具与失败结果", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()

  # 非编辑工具不记录
  tracker$note_call("r1", "Read", list(file_path = "R/a.R"))
  tracker$note_result("r1", is_error = FALSE)
  expect_null(tracker$flush())

  # 编辑但结果失败 → 不揭示
  tracker$note_call("e1", "Edit", list(file_path = "R/a.R"))
  tracker$note_result("e1", is_error = TRUE)
  expect_null(tracker$flush())

  # 成功编辑覆盖失败：最近一次成功才算
  tracker$note_call("e2", "Edit", list(file_path = "R/ok.R"))
  tracker$note_result("e2", is_error = TRUE)
  tracker$note_call("e3", "MultiEdit", list(file_path = "R/win.R"))
  tracker$note_result("e3", is_error = FALSE)
  expect_identical(tracker$flush(), "R/win.R")
})

test_that(".new_edit_reveal_tracker 支持 path 别名且无 file_path 时忽略", {
  tracker <- shinyAssistantUI:::.new_edit_reveal_tracker()
  tracker$note_call("n1", "NotebookEdit", list(path = "notebooks/x.ipynb"))
  tracker$note_result("n1", is_error = FALSE)
  expect_identical(tracker$flush(), "notebooks/x.ipynb")

  tracker$note_call("n2", "Edit", list(old_string = "a", new_string = "b"))
  tracker$note_result("n2", is_error = FALSE)
  expect_null(tracker$flush())
})


test_that(".addin_resolve_file_path resolves root and unique hot-index files", {
  project <- tempfile("open-file-")
  dir.create(file.path(project, "subfolder"), recursive = TRUE)
  root_file <- file.path(project, "root.R")
  nested_file <- file.path(project, "subfolder", "dm.R")
  file.create(root_file, nested_file)

  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path("root.R", project),
    normalizePath(root_file, winslash = "/")
  )
  peek <- function() list(list(kind = "file", path = "subfolder/dm.R"))
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path("dm.R", project, peek),
    normalizePath(nested_file, winslash = "/")
  )
})

test_that(".addin_resolve_file_path keeps cold, missing, ambiguous and stale fallbacks silent", {
  project <- tempfile("open-file-")
  dir.create(project)

  expect_null(shinyAssistantUI:::.addin_resolve_file_path("dm.R", project, function() NULL))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "subfolder/ae.R"))
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project,
    function() list(
      list(kind = "file", path = "adam/dm.R"),
      list(kind = "file", path = "sdtm/dm.R")
    )
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "deleted/dm.R"))
  ))
  expect_null(shinyAssistantUI:::.addin_resolve_file_path(
    "dm.R", project, function() list(list(kind = "file", path = "../dm.R"))
  ))
})

test_that(".addin_open_file no longer repeats rstudioapi isAvailable per click", {
  source_text <- paste(deparse(body(shinyAssistantUI:::.addin_open_file)), collapse = "\n")
  expect_false(grepl("isAvailable", source_text, fixed = TRUE))
  expect_true(grepl("getSourceEditorContext", source_text, fixed = TRUE))
  expect_true(grepl("navigateToFile", source_text, fixed = TRUE))
})

test_that("explicit home-relative references expand before project resolution", {
  root <- tempfile("open-file-home-")
  home <- file.path(root, "home")
  project <- file.path(root, "project")
  dir.create(file.path(home, ".config", "example"), recursive = TRUE)
  dir.create(file.path(project, "~", ".config", "example"), recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  withr::local_envvar(HOME = home)
  target <- file.path(home, ".config", "example", "settings.json")
  wrong <- file.path(project, "~", ".config", "example", "settings.json")
  file.create(target, wrong)
  expect_identical(
    .addin_resolve_file_path("~/.config/example/settings.json", project),
    normalizePath(target, winslash = "/")
  )
  expect_null(.addin_resolve_file_path("~/.config/example/missing.json", project))
  expect_null(.addin_resolve_file_path("settings.json", project))
  dir.create(file.path(project, "directory.json"))
  expect_null(.addin_resolve_file_path("directory.json", project))
})

test_that("server confirms bounded file batches without navigating or reading content", {
  root <- tempfile("file-reference-server-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  target <- file.path(root, "exists.R")
  file.create(target)
  opened <- 0L
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = function(...) NULL, working_dir = root,
                      on_open_file = function(...) opened <<- opened + 1L)
  }, {
    sent <- list()
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    expect_true(widget_config(output$chat)$file_open)
    expect_identical(widget_config(output$chat)$file_reference_protocol, 1L)
    session$setInputs(chat_input_resolve_files = list(
      version = 1L, requestId = "files-1", threadId = "history",
      paths = list("exists.R", "missing.R")
    ))
    for (i in seq_len(40L)) {
      later::run_now(0.01)
      session$flushReact()
      if (any(vapply(sent, function(frame) identical(frame$type, "chat_input:file-references"), logical(1)))) break
    }
    frames <- Filter(function(frame) identical(frame$type, "chat_input:file-references"), sent)
    expect_length(frames, 1L)
    expect_identical(frames[[1L]]$message, list(
      version = 1L, requestId = "files-1", threadId = "history",
      files = list(
        list(path = "exists.R", resolvedPath = normalizePath(target, winslash = "/")),
        list(path = "missing.R", resolvedPath = NULL)
      )
    ))
    expect_identical(opened, 0L)
    expect_warning(session$setInputs(chat_input_resolve_files = list(
      version = 1L, requestId = "too-many", threadId = "history",
      paths = as.list(paste0(seq_len(33L), ".R"))
    )), "Invalid file-reference request")
    expect_length(Filter(function(frame) identical(frame$type, "chat_input:file-references"), sent), 1L)
  })
})

test_that("custom confirmation providers receive thread and project and require an open callback", {
  requests <- list()
  domains <- logical()
  shiny::testServer(function(input, output, session) {
    signal <- shiny::reactiveVal("readable")
    assistantUIServer(
      "chat", handler = function(...) NULL, on_open_file = function(...) NULL,
      file_reference_resolver = function(path, thread_id, project) {
        domains <<- c(domains, identical(shiny::getDefaultReactiveDomain(), session) &&
                        identical(signal(), "readable"))
        requests[[length(requests) + 1L]] <<- list(path, thread_id, project)
        if (identical(path, "known.R")) "/host/known.R" else NULL
      }
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input_resolve_files = list(
      version = 1L, requestId = "custom", threadId = "thread-a", project = "/project-a",
      paths = list("known.R", "unknown.R")
    ))
    for (i in seq_len(40L)) {
      later::run_now(0.01)
      session$flushReact()
      if (length(requests) == 2L) break
    }
    expect_identical(requests, list(
      list("known.R", "thread-a", "/project-a"),
      list("unknown.R", "thread-a", "/project-a")
    ))
    expect_identical(domains, c(TRUE, TRUE))
  })
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = function(...) NULL)
  }, {
    expect_false(isTRUE(widget_config(output$chat)$file_open))
    expect_null(widget_config(output$chat)$file_reference_protocol)
  })
})

test_that("missing files and navigation failures notify instead of silently succeeding", {
  skip_if_not_installed("rstudioapi")
  root <- tempfile("open-file-notify-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  target <- file.path(root, "exists.R")
  file.create(target)
  notices <- list()
  navigations <- list()
  testthat::local_mocked_bindings(
    showNotification = function(ui, type, ...) {
      notices[[length(notices) + 1L]] <<- list(message = as.character(ui), type = type)
      invisible(NULL)
    },
    .package = "shiny"
  )
  testthat::local_mocked_bindings(
    getSourceEditorContext = function() list(path = ""),
    navigateToFile = function(file, line, ...) {
      navigations[[length(navigations) + 1L]] <<- list(path = file, line = line)
      if (line == 99L) stop("Synthetic editor failure")
      invisible(NULL)
    },
    .package = "rstudioapi"
  )
  .addin_open_file("missing.R", project = root)
  expect_length(navigations, 0L)
  expect_length(notices, 1L)
  expect_match(notices[[1L]]$message, "Unable to locate file", fixed = TRUE)

  .addin_open_file("exists.R", 12L, project = root)
  expect_identical(navigations[[1L]], list(path = normalizePath(target, winslash = "/"), line = 12L))
  expect_length(notices, 1L)
  .addin_open_file("exists.R", 99L, project = root)
  expect_length(notices, 2L)
  expect_match(notices[[2L]]$message, "Synthetic editor failure", fixed = TRUE)
})

test_that("explicit clicks focus the current file and honor its line while automatic reveal stays quiet", {
  skip_if_not_installed("rstudioapi")
  target <- tempfile(fileext = ".R")
  file.create(target)
  on.exit(unlink(target), add = TRUE)
  target <- normalizePath(target, winslash = "/")
  navigations <- list()
  context_reads <- 0L
  testthat::local_mocked_bindings(
    getSourceEditorContext = function() {
      context_reads <<- context_reads + 1L
      list(path = target)
    },
    navigateToFile = function(file, line, ...) {
      navigations[[length(navigations) + 1L]] <<- list(path = file, line = line)
      invisible(NULL)
    },
    .package = "rstudioapi"
  )
  expect_true(.addin_open_file(target, 42L))
  expect_identical(navigations, list(list(path = target, line = 42L)))
  expect_identical(context_reads, 0L)
  expect_true(.addin_open_file(target, focus = FALSE))
  expect_length(navigations, 1L)
  expect_identical(context_reads, 1L)
})

test_that("file opening acknowledges actual callback outcomes without changing legacy requests", {
  calls <- list()
  finish <- NULL
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = function(...) NULL,
      on_open_file = function(path, line = NULL, thread_id = NULL, project = NULL, focus = FALSE) {
        calls[[length(calls) + 1L]] <<- list(path, line, thread_id, project, focus)
        if (path == "pending.R") {
          return(promises::promise(function(resolve, reject) finish <<- resolve))
        }
        if (path == "failed.R") return(FALSE)
        NULL
      })
  }, {
    sent <- list()
    session$sendCustomMessage <- function(type, message) {
      if (type == "chat_input:file-open-result") sent[[length(sent) + 1L]] <<- message
    }
    session$flushReact()
    expect_identical(widget_config(output$chat)$file_open_protocol, 1L)
    session$setInputs(chat_input_open_file = list(
      version = 1L, requestId = "first", path = "pending.R", line = 4L, threadId = "history", project = "/project"
    ))
    expect_length(sent, 0L)
    expect_identical(calls[[1L]], list("pending.R", 4L, "history", "/project", TRUE))
    finish(TRUE)
    for (i in seq_len(20L)) {
      later::run_now(0.01)
      session$flushReact()
      if (length(sent)) break
    }
    expect_identical(sent[[1L]], list(version = 1L, requestId = "first", threadId = "history", ok = TRUE))
    session$setInputs(chat_input_open_file = list(
      version = 1L, requestId = "failed", path = "failed.R", threadId = "history"
    ))
    expect_identical(sent[[2L]], list(version = 1L, requestId = "failed", threadId = "history", ok = FALSE))
    session$setInputs(chat_input_open_file = list(path = "legacy.R"))
    expect_length(calls, 3L)
    expect_length(sent, 2L)
  })
})


test_that(".addin_resolve_file_path safely handles a repeated cwd basename prefix", {
  parent <- tempfile("open-file-prefix-")
  project <- file.path(parent, "ERP")
  dir.create(project, recursive = TRUE)
  name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
  root_file <- file.path(project, name)
  file.create(root_file)

  # cwd已经是ERP；Claude输出ERP/file时，direct ERP/ERP/file不存在才回退根文件。
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP", name), project),
    normalizePath(root_file, winslash = "/")
  )
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(paste0("ERP\\\\", name), project),
    normalizePath(root_file, winslash = "/")
  )
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP-copy", name), project)
  )

  # 若真实ERP/ERP/file存在，即使根目录有同名文件，也必须由direct candidate优先命中。
  nested_dir <- file.path(project, "ERP")
  dir.create(nested_dir)
  nested_file <- file.path(nested_dir, name)
  file.create(nested_file)
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(file.path("ERP", name), project),
    normalizePath(nested_file, winslash = "/")
  )
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(paste0("ERP\\\\", name), project),
    normalizePath(nested_file, winslash = "/")
  )

  # fallback和相对direct候选都不得通过..或symlink逃出cwd；显式绝对路径保持兼容。
  outside <- file.path(parent, "outside.md")
  file.create(outside)
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path("ERP/../outside.md", project)
  )
  expect_null(
    shinyAssistantUI:::.addin_resolve_file_path("ERP/../../outside.md", project)
  )
  outside_link <- file.path(nested_dir, "outside-link.md")
  if (isTRUE(file.symlink(outside, outside_link))) {
    expect_null(
      shinyAssistantUI:::.addin_resolve_file_path("ERP/outside-link.md", project)
    )
  }
  expect_identical(
    shinyAssistantUI:::.addin_resolve_file_path(outside, project),
    normalizePath(outside, winslash = "/")
  )
})
