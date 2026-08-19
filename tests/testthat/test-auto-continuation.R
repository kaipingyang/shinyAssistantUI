test_that("assistantUIServer forwards auto-continuation before completing the owning run", {
  sent <- list()
  handler <- function(message, on_auto_continue, on_done, ...) {
    on_auto_continue(
      notice = "Continuing automatically\u2026",
      prompt = "Please continue from the completed tool results."
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
    expect_lt(
      which(vapply(sent, function(x) identical(x$type, "chat_input:auto-continue"), logical(1))),
      which(vapply(sent, function(x) identical(x$type, "chat_input:done"), logical(1)))
    )
  })
})
