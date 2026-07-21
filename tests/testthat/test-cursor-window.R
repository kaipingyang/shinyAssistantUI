# Plan 14 A4：无选区时取光标位置 + 周围窗口作为上下文（受眼睛门控由 .append_ide_context 保证）。
# 纯函数 .addin_cursor_window(contents, row, radius)。

test_that(".addin_cursor_window 取光标 ±radius 行", {
  contents <- paste0("line", 1:30)
  w <- shinyAssistantUI:::.addin_cursor_window(contents, 15L, radius = 3L)
  expect_identical(w$start_line, 12L)
  expect_identical(w$end_line, 18L)
  expect_identical(w$cursor_line, 15L)
  expect_identical(w$text, paste(paste0("line", 12:18), collapse = "\n"))
})

test_that(".addin_cursor_window 边界裁剪与空输入", {
  contents <- paste0("l", 1:5)
  w1 <- shinyAssistantUI:::.addin_cursor_window(contents, 1L, radius = 3L)
  expect_identical(w1$start_line, 1L); expect_identical(w1$end_line, 4L)
  w2 <- shinyAssistantUI:::.addin_cursor_window(contents, 99L, radius = 3L)  # 越界 → 夹到末行
  expect_identical(w2$cursor_line, 5L); expect_identical(w2$end_line, 5L)
  expect_null(shinyAssistantUI:::.addin_cursor_window(character(0), 3L))
  expect_null(shinyAssistantUI:::.addin_cursor_window(contents, NA_integer_))
})
