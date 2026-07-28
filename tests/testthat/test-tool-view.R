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
