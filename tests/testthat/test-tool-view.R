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


test_that(".tool_edit_start_line normalizes CRLF and rejects ambiguous duplicate blocks", {
  f <- tempfile(fileext = ".R")
  writeBin(charToRaw("top\r\ntarget\r\nnext\r\nmiddle\r\ntarget\r\nnext\r\n"), f)
  on.exit(unlink(f), add = TRUE)
  expect_null(
    shinyAssistantUI:::.tool_edit_start_line(f, "target\r\nnext")
  )
})



test_that(".tool_edit_start_line rejects files above the 5MB guard", {
  file <- tempfile(fileext = ".R")
  on.exit(unlink(file), add = TRUE)
  connection <- file(file, open = "wb")
  on.exit(try(close(connection), silent = TRUE), add = TRUE)
  writeBin(raw(5e6 + 1L), connection)
  close(connection)
  expect_null(shinyAssistantUI:::.tool_edit_start_line(file, "target"))
})
test_that(".tool_edit_start_line never guesses from the first line of a mismatched multiline block", {
  f <- tempfile(fileext = ".R")
  writeLines(c("top", "target", "different", "bottom"), f)
  on.exit(unlink(f), add = TRUE)
  expect_null(
    shinyAssistantUI:::.tool_edit_start_line(f, "target\nexpected")
  )
})


test_that(".tool_edit_start_line_from_content recovers a unique pre-edit line", {
  original <- paste(c("line1", "line2", "line3", "target <- old", "line5"), collapse = "\r\n")
  expect_identical(
    shinyAssistantUI:::.tool_edit_start_line_from_content(
      original, "target <- old"
    ),
    4L
  )
  expect_null(
    shinyAssistantUI:::.tool_edit_start_line_from_content(
      "target <- old\nother\ntarget <- old", "target <- old"
    )
  )
  expect_null(
    shinyAssistantUI:::.tool_edit_start_line_from_content(
      strrep("x", 5e6 + 1L), "x"
    )
  )
})

test_that(".claude_edit_result_recovery uses only successful unique Edit evidence", {
  args <- list(
    file_path = "demo.R", old_string = "target <- old",
    new_string = "target <- new", replace_all = FALSE
  )
  result <- list(
    filePath = "demo.R", oldString = "target <- old",
    newString = "target <- new",
    originalFile = "line1\nline2\nline3\ntarget <- old\nline5\n",
    replaceAll = FALSE
  )
  recovered <- shinyAssistantUI:::.claude_edit_result_recovery(result, args)
  expect_identical(recovered$diffStartLine, 4L)
  expect_identical(recovered$args, args)

  result$replaceAll <- TRUE
  expect_identical(
    shinyAssistantUI:::.claude_edit_result_recovery(result, args)$diffStartLine,
    4L
  )

  result$originalFile <- "target <- old\nother\ntarget <- old\n"
  expect_null(shinyAssistantUI:::.claude_edit_result_recovery(result, args))
  expect_null(shinyAssistantUI:::.claude_edit_result_recovery("Edited", args))
})
