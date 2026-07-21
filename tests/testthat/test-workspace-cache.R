# 任务4：workspace 索引缓存（git HEAD 键）+ 文件夹推导正确性

test_that(".addin_workspace_index_cached 命中缓存则不重建（同 project+HEAD）", {
  cache_path <- tempfile(fileext = ".rds")
  proj <- tempfile("proj"); dir.create(proj)
  build_calls <- 0L
  fake_index <- list(list(kind = "file", path = "R/app.R"))

  testthat::local_mocked_bindings(
    .addin_git_head = function(project) "deadbeef",
    .addin_workspace_index = function(project, max_files = 10000L) {
      build_calls <<- build_calls + 1L
      fake_index
    }
  )

  first <- shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)
  second <- shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)

  expect_identical(first, fake_index)
  expect_identical(second, fake_index)
  expect_identical(build_calls, 1L)  # 第二次命中缓存，不重建
})

test_that(".addin_workspace_index_cached 在 HEAD 变化时失效重建", {
  cache_path <- tempfile(fileext = ".rds")
  proj <- tempfile("proj"); dir.create(proj)
  build_calls <- 0L
  head_val <- "aaa"

  testthat::local_mocked_bindings(
    .addin_git_head = function(project) head_val,
    .addin_workspace_index = function(project, max_files = 10000L) {
      build_calls <<- build_calls + 1L
      list(list(kind = "file", path = paste0("f-", build_calls, ".R")))
    }
  )

  shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)
  head_val <- "bbb"  # HEAD 变化
  shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)
  expect_identical(build_calls, 2L)
})

test_that(".addin_workspace_index_cached 非 git（HEAD NULL）不写缓存、每次重建", {
  cache_path <- tempfile(fileext = ".rds")
  proj <- tempfile("proj"); dir.create(proj)
  build_calls <- 0L

  testthat::local_mocked_bindings(
    .addin_git_head = function(project) NULL,
    .addin_workspace_index = function(project, max_files = 10000L) {
      build_calls <<- build_calls + 1L
      list()
    }
  )

  shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)
  shinyAssistantUI:::.addin_workspace_index_cached(proj, cache_path)
  expect_identical(build_calls, 2L)
  expect_false(file.exists(cache_path))
})
