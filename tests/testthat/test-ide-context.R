test_that("IDE context normalization hides selection without losing active file", {
  raw <- list(
    path = "/proj/R/app.R", rel = "R/app.R", selection = "secret <- 42",
    first_line = 7L, last_line = 9L
  )
  visible <- .normalize_ide_context(raw, selection_visible = TRUE)
  hidden <- .normalize_ide_context(raw, selection_visible = FALSE)

  expect_identical(visible$relative_path, "R/app.R")
  expect_identical(visible$selection_text, "secret <- 42")
  expect_identical(hidden$relative_path, "R/app.R")
  expect_null(hidden$selection_text)
  expect_false(hidden$selection_visible)
})

test_that("IDE context suffix is structured, bounded, and removable from history", {
  ctx <- list(
    relative_path = "R/app.R", selection_text = strrep("x", 5000L),
    start_line = 3L, end_line = 8L, selection_visible = TRUE
  )
  sent <- .append_ide_context("Please explain this", ctx)
  expect_match(sent, "Please explain this", fixed = TRUE)
  expect_match(sent, "R/app.R", fixed = TRUE)
  expect_match(sent, "lines 3-8", fixed = TRUE)
  expect_match(sent, "truncated", fixed = TRUE)
  expect_lt(nchar(sent), 4600L)
  expect_identical(.strip_ide_context_suffix(sent), "Please explain this")
  expect_identical(.append_ide_context("plain", NULL), "plain")
})

test_that("historical user messages never expose injected IDE context", {
  sent <- .append_ide_context(
    "Refactor it",
    list(relative_path = "R/app.R", selection_text = "private_value", start_line = 1L,
         end_line = 1L, selection_visible = TRUE)
  )
  out <- .claude_msgs_to_thread(list(
    list(type = "user", uuid = "u-context", message = list(content = sent))
  ))
  expect_identical(out[[1L]]$content[[1L]]$text, "Refactor it")
  expect_false(grepl("private_value", out[[1L]]$content[[1L]]$text, fixed = TRUE))
})
