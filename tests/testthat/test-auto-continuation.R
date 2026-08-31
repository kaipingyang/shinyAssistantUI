test_that("assistantUIServer forwards auto-continuation before completing the owning run", {
  sent <- list()
  handler <- function(message, on_auto_continue, on_done, ...) {
    on_auto_continue(
      notice = "Continuing automatically\u2026",
      prompt = "Please continue from the completed tool results.",
      kind = "tool-postlude"
    )
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "inspect", threadId = "thread-auto", runId = "run-auto",
      attachments = list(), ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (any(vapply(sent, function(x) identical(x$type, "chat_input:done"), logical(1)))) break
    }

    recovery <- Filter(function(x) identical(x$type, "chat_input:auto-continue"), sent)
    done <- Filter(function(x) identical(x$type, "chat_input:done"), sent)
    expect_length(recovery, 1L)
    expect_length(done, 1L)
    expect_identical(recovery[[1L]]$message$threadId, "thread-auto")
    expect_identical(recovery[[1L]]$message$runId, "run-auto")
    expect_match(recovery[[1L]]$message$notice, "Continuing automatically")
    expect_match(recovery[[1L]]$message$prompt, "completed tool results")
    expect_identical(recovery[[1L]]$message$kind, "tool-postlude")
    expect_lt(
      which(vapply(sent, function(x) identical(x$type, "chat_input:auto-continue"), logical(1))),
      which(vapply(sent, function(x) identical(x$type, "chat_input:done"), logical(1)))
    )
  })
})


test_that("assistantUIServer forwards hidden continuation kind only to compatible handlers", {
  received <- character()
  compatible <- function(message, continuation_kind = NULL, on_done, ...) {
    received <<- c(received, continuation_kind %||% "ordinary")
    on_done()
  }
  legacy_calls <- 0L
  legacy <- function(message, on_done) {
    legacy_calls <<- legacy_calls + 1L
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = compatible)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "继续", threadId = "thread-kind", runId = "run-kind",
      continuationKind = "minimal", attachments = list(), ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (length(received)) break
    }
    expect_identical(received, "minimal")
  })

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = legacy)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "继续", threadId = "thread-legacy", runId = "run-legacy",
      continuationKind = "minimal", attachments = list(), ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (legacy_calls > 0L) break
    }
    expect_identical(legacy_calls, 1L)
  })
})