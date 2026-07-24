# Plan 20 — background-job 启动器。可单测的部分：脚本生成、主会话编排、job 内运行。
# 真实 RStudio background job 的行为(子进程 rstudioapi 回连等)由用户在 RStudio 里按清单验证。

test_that(".claude_bg_launch_script embeds libPaths, library, and a parseable run call", {
  s <- shinyAssistantUI:::.claude_bg_launch_script("/tmp/spec.rds", 4321L, "127.0.0.1",
                                                   c("/lib/a", "/lib/b"))
  txt <- paste(s, collapse = "\n")
  expect_match(txt, "library(shinyAssistantUI)", fixed = TRUE)
  expect_match(txt, ".libPaths(", fixed = TRUE)
  expect_match(txt, '"/lib/a"', fixed = TRUE)
  expect_match(txt, '"/lib/b"', fixed = TRUE)
  expect_match(txt, ".claude_run_in_job(", fixed = TRUE)
  expect_match(txt, '"/tmp/spec.rds"', fixed = TRUE)
  expect_match(txt, "4321L", fixed = TRUE)
  expect_match(txt, '"127.0.0.1"', fixed = TRUE)
  expect_silent(parse(text = txt))          # 生成的脚本语法正确
})

test_that(".run_claude_bg_job serializes spec, launches job, waits, shows viewer", {
  spec <- list(project = "/proj", options = NULL, permission_mode = "plan",
               prewarm = FALSE, models = c("sonnet"))
  seen <- new.env()
  res <- shinyAssistantUI:::.run_claude_bg_job(
    spec, host = "127.0.0.1", port = 4321L, libpaths = c("/lib/x"),
    job_run     = function(path, name, workingDir) {
      seen$path <- path; seen$name <- name; seen$wd <- workingDir
    },
    show_viewer = function(u) seen$url <- u,
    wait_ready  = function(host, port) TRUE
  )
  expect_identical(res$port, 4321L)
  expect_identical(res$url, "http://127.0.0.1:4321")
  expect_true(res$ready)
  rt <- readRDS(res$spec_path)
  expect_identical(rt$permission_mode, "plan")
  expect_identical(rt$models, c("sonnet"))
  expect_identical(seen$name, "Claude Code Chat")
  expect_identical(seen$wd, "/proj")
  script_txt <- paste(readLines(seen$path), collapse = "\n")
  expect_match(script_txt, "4321L", fixed = TRUE)
  expect_match(script_txt, ".claude_run_in_job(", fixed = TRUE)
  expect_identical(seen$url, "http://127.0.0.1:4321")
})

test_that(".run_claude_bg_job skips viewer when the app never becomes ready", {
  shown <- FALSE
  res <- shinyAssistantUI:::.run_claude_bg_job(
    list(project = "/p"), port = 5000L,
    job_run     = function(path, name, workingDir) NULL,
    show_viewer = function(u) shown <<- TRUE,
    wait_ready  = function(host, port) FALSE
  )
  expect_false(res$ready)
  expect_false(shown)
})

test_that(".claude_run_in_job reads spec, builds app with those params, runs on the port", {
  spec_path <- tempfile(fileext = ".rds")
  saveRDS(list(project = "/proj", options = NULL, permission_mode = "acceptEdits",
               prewarm = TRUE, models = c("opus")), spec_path)
  cap <- new.env()
  testthat::local_mocked_bindings(
    .claude_chat_app = function(project, options, permission_mode, prewarm, models) {
      cap$args <- list(project = project, permission_mode = permission_mode,
                       prewarm = prewarm, models = models)
      "APP_OBJ"
    }
  )
  testthat::local_mocked_bindings(
    runApp = function(app, port, host, launch.browser) {
      cap$app <- app; cap$port <- port; cap$host <- host; "RAN"
    },
    .package = "shiny"
  )
  shinyAssistantUI:::.claude_run_in_job(spec_path, port = 6001L, host = "127.0.0.1")
  expect_identical(cap$args$project, "/proj")
  expect_identical(cap$args$permission_mode, "acceptEdits")
  expect_true(cap$args$prewarm)
  expect_identical(cap$args$models, c("opus"))
  expect_identical(cap$app, "APP_OBJ")
  expect_identical(cap$port, 6001L)
})
