test_that("session close invokes only that session's registered cancellation", {
  state <- new.env(parent = emptyenv())
  state$cancelled <- character()
  state$resolvers <- list()
  state$settled <- character()
  handler <- function(thread_id, register_cancel, ...) {
    promise <- promises::promise(function(resolve, reject) {
      state$resolvers[[thread_id]] <- resolve
      register_cancel(function() {
        state$cancelled <- c(state$cancelled, thread_id)
        resolve(NULL)
      })
    })
    promises::then(promise, function(value) {
      state$settled <- c(state$settled, thread_id)
      NULL
    })
  }
  on.exit(
    {
      for (resolve in state$resolvers) resolve(NULL)
      deadline <- Sys.time() + 2
      while (length(state$settled) < length(state$resolvers) && Sys.time() < deadline) {
        later::run_now(0.01)
      }
    },
    add = TRUE
  )
  start <- function(session, thread) {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "Synthetic pending turn", threadId = thread,
      runId = paste0("run-", thread), ts = 1
    ))
    deadline <- Sys.time() + 5
    while (is.null(state$resolvers[[thread]])) {
      session$flushReact()
      later::run_now(0.01)
      if (Sys.time() > deadline) stop("Session fixture did not start")
    }
  }
  first <- shiny::MockShinySession$new()
  second <- shiny::MockShinySession$new()
  on.exit(
    {
      first$close()
      second$close()
    },
    add = TRUE
  )
  shiny::withReactiveDomain(first, assistantUIServer("chat", handler))
  shiny::withReactiveDomain(second, assistantUIServer("chat", handler))
  start(first, "first")
  start(second, "second")
  second$close()
  expect_identical(state$cancelled, "second")
  second$close()
  expect_identical(state$cancelled, "second")
  expect_false("first" %in% state$cancelled)
  first$close()
  expect_identical(state$cancelled, c("second", "first"))
})
