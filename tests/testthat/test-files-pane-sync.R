# Bug2：Files 面板同步 —— 开启开关立即跟随当前目录；再点"当前目录"也刷新（不因 early-return 漏掉）。

test_that(".addin_files_pane_navigate 在非 RStudio 环境安全无操作", {
  expect_false(shinyAssistantUI:::.addin_files_pane_navigate(NULL))
  expect_false(shinyAssistantUI:::.addin_files_pane_navigate(""))
  # 非 RStudio（rstudioapi 不可用）→ FALSE，且不报错
  expect_false(shinyAssistantUI:::.addin_files_pane_navigate(tempdir()))
})

test_that("开启同步 + 重选当前目录 都会导航 Files 面板（Bug2）", {
  skip_if_not_installed("shiny")
  temp_home <- normalizePath(tempfile("home"), winslash = "/", mustWork = FALSE)
  dir.create(temp_home)
  dir.create(file.path(temp_home, ".claude_addin"))
  withr::local_envvar(c(HOME = temp_home))

  proj <- normalizePath(tempfile("proj"), winslash = "/", mustWork = FALSE)
  dir.create(proj)

  nav_calls <- character()
  server_args <- NULL
  testthat::local_mocked_bindings(
    make_claude_handler = function(options, cwd_provider = NULL, models = NULL, session_map_path) {
      h <- function(...) NULL
      attr(h, "reset_clients") <- function() invisible(NULL)
      h
    },
    load_claude_skills = function(project_dir) list(),
    make_claude_session_loader = function(session_map_path) function(...) NULL,
    .addin_files_pane_navigate = function(path) {
      nav_calls[[length(nav_calls) + 1L]] <<- as.character(path); TRUE
    },
    assistantUIServer = function(...) {
      server_args <<- list(...)
      list(send_sessions = function(...) NULL, send_working_dir = function(...) NULL,
           send_projects = function(...) NULL)
    }
  )

  app <- .claude_chat_app(proj, options = list(), prewarm = FALSE)
  shiny::testServer(app$serverFuncSource(), {
    session$flushReact()
    server_args$on_toggle_files_pane_follow(TRUE)   # 开启 → 立即导航当前目录
    server_args$on_set_working_dir(proj)            # 再点当前目录（同目录）→ 仍导航
  })

  expect_gte(length(nav_calls), 2L)
  expect_true(all(nav_calls == proj))
})
