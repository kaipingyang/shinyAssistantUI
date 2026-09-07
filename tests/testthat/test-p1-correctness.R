test_that("feedback capability is published only when on_feedback is callable", {
  handler <- function(message, on_done, ...) on_done()

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    expect_false(isTRUE(widget_config(output$chat)$feedback_enabled))
  })

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, on_feedback = function(...) NULL)
  }, {
    expect_true(isTRUE(widget_config(output$chat)$feedback_enabled))
  })
})

test_that("reload forwards attachments and replays the original quote", {
  state <- new.env(parent = emptyenv())
  state$captured <- NULL
  handler <- function(message, attachments, is_reload, on_done, ...) {
    state$captured <- list(
      message = message,
      attachments = attachments,
      is_reload = is_reload
    )
    on_done()
  }
  attachment <- list(
    type = "text", name = "notes.txt", data = "ATTACHMENT_BODY",
    contentType = "text/plain"
  )

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "reload",
      text = "analyze",
      threadId = "thread-reload",
      runId = "run-reload",
      attachments = list(attachment),
      quote = list(text = "ORIGINAL_QUOTE", messageId = "source-1"),
      ts = 1
    ))
    session$flushReact()
    for (i in seq_len(40L)) {
      later::run_now()
      session$flushReact()
      if (!is.null(state$captured)) break
    }

    expect_true(isTRUE(state$captured$is_reload))
    expect_identical(state$captured$attachments, list(attachment))
    expect_identical(state$captured$message, "> ORIGINAL_QUOTE\n\nanalyze")
  })
})
