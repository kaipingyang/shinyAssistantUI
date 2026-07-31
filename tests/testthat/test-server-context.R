test_that("server merges IDE capabilities without replacing permission capability", {
  handler <- function(...) NULL
  attr(handler, "action_handler") <- function(...) NULL
  attr(handler, "ui_capabilities") <- list(
    permission_mode = list(
      value = "default",
      options = lapply(c("default", "plan", "acceptEdits", "bypassPermissions"),
                       function(x) list(value = x, label = x))
    )
  )

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler,
      ide_context_provider = function() list(rel = "R/app.R"),
      workspace_search_provider = function(...) list()
    )
  }, {
    caps <- widget_config(output$chat)$ui_capabilities
    expect_identical(caps$contract_version, 1L)
    expect_true(caps$ide_context$submit)
    expect_true(caps$workspace_mentions$search)
    values <- vapply(caps$permission_mode$options, `[[`, character(1), "value")
    expect_identical(values, c("default", "plan", "acceptEdits", "bypassPermissions"))
  })
})

test_that("context provider failures safely produce empty metadata", {
  expect_null(.read_ide_context(function() stop("IDE unavailable"), TRUE))
  expect_null(.ide_context_metadata(NULL))
})
