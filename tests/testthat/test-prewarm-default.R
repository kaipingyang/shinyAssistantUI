test_that("Claude addins default to prewarm while the generic server stays lazy", {
  expect_identical(formals(claude_addin)$prewarm, TRUE)
  expect_identical(formals(claude_workspace_addin)$prewarm, TRUE)
  expect_identical(formals(.claude_chat_app)$prewarm, TRUE)
  expect_identical(formals(assistantUIServer)$prewarm, FALSE)
})

test_that("prewarm documentation matches the stdio run_r architecture", {
  addin_source <- readLines(testthat::test_path("..", "..", "R", "addin.R"), warn = FALSE)
  server_source <- readLines(testthat::test_path("..", "..", "R", "server.R"), warn = FALSE)
  console_source <- readLines(
    testthat::test_path("..", "..", "R", "addin-r-console.R"),
    warn = FALSE
  )

  expect_true(any(grepl(
    "@param prewarm Logical (default `TRUE`)",
    addin_source,
    fixed = TRUE
  )))
  expect_false(any(grepl("leave `FALSE` when the in-process", addin_source, fixed = TRUE)))
  expect_false(any(grepl("~55s", server_source, fixed = TRUE)))
  expect_false(any(grepl("in-process SDK MCP tool", console_source, fixed = TRUE)))
})
