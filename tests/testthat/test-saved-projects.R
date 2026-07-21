# Plan 19：工作目录收藏夹持久化 helper（保存/删除/去重/前插）。

test_that("saved projects：add 去重前插、remove、persist", {
  path <- tempfile(fileext = ".rds")
  expect_identical(shinyAssistantUI:::.read_saved_projects(path), character(0))

  shinyAssistantUI:::.add_saved_project(path, "/tmp/proj-a")
  shinyAssistantUI:::.add_saved_project(path, "/tmp/proj-b")
  expect_identical(shinyAssistantUI:::.read_saved_projects(path), c("/tmp/proj-b", "/tmp/proj-a"))  # 最近前插

  shinyAssistantUI:::.add_saved_project(path, "/tmp/proj-a")  # 已存在 → 去重 + 提到最前
  expect_identical(shinyAssistantUI:::.read_saved_projects(path), c("/tmp/proj-a", "/tmp/proj-b"))

  shinyAssistantUI:::.remove_saved_project(path, "/tmp/proj-a")
  expect_identical(shinyAssistantUI:::.read_saved_projects(path), "/tmp/proj-b")
})

test_that("空/非法路径不入收藏", {
  path <- tempfile(fileext = ".rds")
  shinyAssistantUI:::.add_saved_project(path, "")
  shinyAssistantUI:::.add_saved_project(path, NULL)
  expect_identical(shinyAssistantUI:::.read_saved_projects(path), character(0))
})
