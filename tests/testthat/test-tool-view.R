test_that("assistant_tool_view code kind builds argsView", {
  v <- assistant_tool_view("code", field = "code", lang = "r")
  expect_named(v, "argsView")
  expect_equal(v$argsView$kind, "code")
  expect_equal(v$argsView$field, "code")
  expect_equal(v$argsView$lang, "r")
})

test_that("code kind omits NULL field/lang (client applies defaults)", {
  v <- assistant_tool_view("code")
  expect_equal(v$argsView, list(kind = "code"))
  expect_false("field" %in% names(v$argsView))
  expect_false("lang" %in% names(v$argsView))
})

test_that("diff kind builds camelCase fields matching the client hint", {
  v <- assistant_tool_view("diff", old_field = "before", new_field = "after",
                           file_field = "path")
  expect_equal(v$argsView$kind, "diff")
  expect_equal(v$argsView$oldField, "before")
  expect_equal(v$argsView$newField, "after")
  expect_equal(v$argsView$fileField, "path")
  # 不应泄漏 code 专属键
  expect_false("field" %in% names(v$argsView))
})

test_that("diff kind omits NULL fields", {
  v <- assistant_tool_view("diff")
  expect_equal(v$argsView, list(kind = "diff"))
})

test_that("invalid kind errors via match.arg", {
  expect_error(assistant_tool_view("table"))
})

test_that("non-string field/lang error", {
  expect_error(assistant_tool_view("code", field = 1), "field")
  expect_error(assistant_tool_view("code", lang = c("r", "py")), "lang")
})

test_that("result merges cleanly into an annotations list", {
  ann <- c(list(requiresApproval = TRUE), assistant_tool_view("code", lang = "r"))
  expect_true(ann$requiresApproval)
  expect_equal(ann$argsView$kind, "code")
  expect_equal(ann$argsView$lang, "r")
})


test_that(".tool_edit_start_line finds the 1-based line of old_string", {
  f <- tempfile(fileext = ".R")
  writeLines(c("a <- 1", "b <- 2", "mean(x)", "c <- 3"), f)
  on.exit(unlink(f), add = TRUE)
  expect_equal(shinyAssistantUI:::.tool_edit_start_line(f, "mean(x)"), 3L)
  # 多行块
  expect_equal(shinyAssistantUI:::.tool_edit_start_line(f, "b <- 2\nmean(x)"), 2L)
})

test_that(".tool_edit_start_line returns NULL when not found or bad input", {
  f <- tempfile(fileext = ".R")
  writeLines(c("a <- 1"), f)
  on.exit(unlink(f), add = TRUE)
  expect_null(shinyAssistantUI:::.tool_edit_start_line(f, "not_present"))
  expect_null(shinyAssistantUI:::.tool_edit_start_line("/no/such/file", "x"))
  expect_null(shinyAssistantUI:::.tool_edit_start_line(f, ""))
  expect_null(shinyAssistantUI:::.tool_edit_start_line(NULL, "x"))
})

test_that(".tool_edit_start_line resolves relative path against base_dir", {
  d <- tempfile(); dir.create(d)
  on.exit(unlink(d, recursive = TRUE), add = TRUE)
  writeLines(c("x", "target_line", "y"), file.path(d, "rel.R"))
  expect_equal(shinyAssistantUI:::.tool_edit_start_line("rel.R", "target_line", d), 2L)
})
