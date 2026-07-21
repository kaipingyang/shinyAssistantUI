# .append_ide_context：眼睛(selection_visible)关闭时，整段 IDE 上下文（含活动文件引用）
# 都不注入 —— 让当前文件“不被 Claude 发现”。开启时注入文件（+选区）。

test_that("selection_visible=FALSE 时不注入任何 IDE 上下文（连文件都藏）", {
  ctx <- list(relative_path = "R/app.R", active_file = "/proj/R/app.R",
              selection_text = "x <- 1", start_line = 4L, end_line = 6L,
              selection_visible = FALSE)
  out <- shinyAssistantUI:::.append_ide_context("hello", ctx)
  expect_identical(out, "hello")                       # 原样返回
  expect_false(grepl("Active file", out, fixed = TRUE))
  expect_false(grepl("ide_context", out, fixed = TRUE))
})

test_that("selection_visible=TRUE 注入活动文件（无选区也注入文件）", {
  ctx <- list(relative_path = "R/app.R", selection_visible = TRUE)
  out <- shinyAssistantUI:::.append_ide_context("hello", ctx)
  expect_true(grepl("Active file: `R/app.R`", out, fixed = TRUE))
})

test_that("selection_visible=TRUE 且有选区时文件与选区都注入", {
  ctx <- list(relative_path = "R/app.R", selection_text = "x <- 1",
              start_line = 4L, end_line = 6L, selection_visible = TRUE)
  out <- shinyAssistantUI:::.append_ide_context("hello", ctx)
  expect_true(grepl("Active file: `R/app.R`", out, fixed = TRUE))
  expect_true(grepl("x <- 1", out, fixed = TRUE))
  expect_true(grepl("lines 4-6", out, fixed = TRUE))
})

test_that("无 selection_visible 字段(非 addin 后端)保持旧行为：注入文件、不注入选区", {
  ctx <- list(relative_path = "R/app.R", selection_text = "x <- 1", start_line = 4L)
  out <- shinyAssistantUI:::.append_ide_context("hello", ctx)
  expect_true(grepl("Active file: `R/app.R`", out, fixed = TRUE))
  expect_false(grepl("x <- 1", out, fixed = TRUE))
})
