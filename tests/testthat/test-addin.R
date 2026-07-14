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
  expect_s3_class(app, "shiny.appobj")
})
