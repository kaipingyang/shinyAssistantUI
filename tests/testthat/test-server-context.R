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


test_that("deferred submissions consume the IDE snapshot reserved at click time", {
  state <- new.env(parent = emptyenv())
  state$selection <- "before-ready"
  state$provider_calls <- 0L
  state$captured <- NULL
  handler <- function(message, on_done, ide_context, ...) {
    state$captured <- ide_context
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      ide_context_provider = function() {
        state$provider_calls <- state$provider_calls + 1L
        list(
          rel = "R/app.R",
          selection = state$selection,
          first_line = 10L,
          last_line = 10L
        )
      }
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input_reserve_submission = list(
      submissionId = "submission-1", threadId = "thread-1", selectionVisible = TRUE
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now()
      session$flushReact()
      if (state$provider_calls > 0L) break
    }
    expect_gt(state$provider_calls, 0L)
    state$selection <- "after-ready"
    session$setInputs(chat_input = list(
      text = "queued", threadId = "thread-1", attachments = list(),
      ideContext = list(selectionVisible = TRUE),
      submissionId = "submission-1", runId = "run-1"
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now()
      if (!is.null(state$captured)) break
    }
    expect_identical(state$captured$selection_text, "before-ready")
  })
})


test_that("an explicitly reserved empty IDE snapshot is not resampled later", {
  state <- new.env(parent = emptyenv())
  state$value <- NULL
  state$calls <- 0L
  state$captured <- "not-called"
  handler <- function(message, on_done, ide_context, ...) {
    state$captured <- ide_context
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      ide_context_provider = function() {
        state$calls <- state$calls + 1L
        state$value
      }
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input_reserve_submission = list(
      submissionId = "empty-1", threadId = "thread-1", selectionVisible = TRUE
    ))
    session$flushReact()
    expect_identical(state$calls, 1L)
    state$value <- list(rel = "R/later.R", selection = "later-selection")
    session$setInputs(chat_input = list(
      text = "queued", threadId = "thread-1", attachments = list(),
      ideContext = list(selectionVisible = TRUE),
      submissionId = "empty-1", runId = "run-empty"
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now()
      if (!identical(state$captured, "not-called")) break
    }
    expect_null(state$captured)
    expect_identical(state$calls, 1L)
  })
})
