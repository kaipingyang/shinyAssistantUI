drain_plan67_loop <- function(seconds = 0.15) {
  deadline <- Sys.time() + seconds
  repeat {
    later::run_now(0)
    if (Sys.time() >= deadline) break
    Sys.sleep(0.005)
  }
  later::run_now(0)
  invisible(NULL)
}

new_plan67_gate <- function(concurrent = TRUE) {
  entered <- character()
  resolvers <- list()
  handler <- function(message, thread_id, on_done) {
    key <- paste(thread_id, message, sep = ":")
    entered <<- c(entered, key)
    promises::promise(function(resolve, reject) {
      resolvers[[key]] <<- function() {
        on_done()
        resolve(NULL)
      }
    })
  }
  if (isTRUE(concurrent)) attr(handler, "supports_concurrent_threads") <- TRUE
  list(
    handler = handler,
    entered = function() entered,
    release = function(key) resolvers[[key]]()
  )
}

submit_plan67 <- function(session, thread_id, text,
                          run_id = paste0("run-", thread_id, "-", text),
                          project = NULL) {
  session$flushReact()
  session$setInputs(chat_input = list(
    text = text, threadId = thread_id, runId = run_id, project = project,
    ts = as.numeric(Sys.time())
  ))
  session$flushReact()
  drain_plan67_loop()
}

test_that("concurrency-safe handlers enter two different threads before either settles", {
  gate <- new_plan67_gate()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first")
    submit_plan67(session, "B", "first")
    expect_setequal(gate$entered(), c("A:first", "B:first"))
    gate$release("A:first")
    gate$release("B:first")
    drain_plan67_loop()
  })
})

test_that("same-thread invocations retain strict single-consumer ordering", {
  gate <- new_plan67_gate()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first")
    submit_plan67(session, "A", "second")
    expect_identical(gate$entered(), "A:first")
    gate$release("A:first")
    drain_plan67_loop()
    expect_identical(gate$entered(), c("A:first", "A:second"))
    gate$release("A:second")
    drain_plan67_loop()
  })
})

test_that("global limit two runs A and B while C waits FIFO", {
  gate <- new_plan67_gate()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first")
    submit_plan67(session, "B", "first")
    submit_plan67(session, "C", "first")
    expect_setequal(gate$entered(), c("A:first", "B:first"))
    gate$release("A:first")
    drain_plan67_loop()
    expect_identical(gate$entered(), c("A:first", "B:first", "C:first"))
    gate$release("B:first")
    gate$release("C:first")
    drain_plan67_loop()
  })
})

test_that("generic handlers remain globally serial even when a higher limit is requested", {
  gate <- new_plan67_gate(concurrent = FALSE)
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first")
    submit_plan67(session, "B", "first")
    expect_identical(gate$entered(), "A:first")
    gate$release("A:first")
    drain_plan67_loop()
    expect_identical(gate$entered(), c("A:first", "B:first"))
    gate$release("B:first")
    drain_plan67_loop()
  })
})

test_that("immediate permit acquisition does not publish a false queued phase", {
  gate <- new_plan67_gate()
  sent <- list()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 2L)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "first", "run-A-immediate")
    phases <- Filter(function(x) identical(x$type, "chat_input:run-state"), sent)
    a_phases <- vapply(Filter(function(x) identical(x$message$threadId, "A"), phases),
                       function(x) x$message$phase, character(1))
    expect_true("connecting" %in% a_phases)
    expect_false("queued" %in% a_phases)
    gate$release("A:first")
    drain_plan67_loop()
  })
})

test_that("cancelling a same-thread queued run does not cancel the active run", {
  entered <- character()
  cancelled <- list()
  cancel_calls <- list()
  resolvers <- list()
  handler <- function(message, thread_id, on_done, register_cancel, is_cancelled) {
    entered <<- c(entered, message)
    cancelled[[message]] <<- is_cancelled
    register_cancel(function() cancel_calls[[message]] <<- (cancel_calls[[message]] %||% 0L) + 1L)
    promises::promise(function(resolve, reject) {
      resolvers[[message]] <<- function() { on_done(); resolve(NULL) }
    })
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first", "run-A-first")
    submit_plan67(session, "A", "second", "run-A-second")
    session$setInputs(chat_input_cancel = list(
      threadId = "A", runId = "run-A-second", ts = 1
    ))
    session$flushReact()
    drain_plan67_loop()

    expect_identical(entered, "first")
    expect_identical(cancel_calls[["first"]] %||% 0L, 0L)
    expect_false(cancelled[["first"]]())
    resolvers[["first"]]()
    drain_plan67_loop()
    expect_identical(entered, "first")
  })
})

test_that("a stale same-thread cancel does not cancel the newer active run", {
  entered <- character()
  cancelled <- list()
  cancel_calls <- list()
  resolvers <- list()
  handler <- function(message, thread_id, on_done, register_cancel, is_cancelled) {
    entered <<- c(entered, message)
    cancelled[[message]] <<- is_cancelled
    register_cancel(function() cancel_calls[[message]] <<- (cancel_calls[[message]] %||% 0L) + 1L)
    promises::promise(function(resolve, reject) {
      resolvers[[message]] <<- function() { on_done(); resolve(NULL) }
    })
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 2L)
  }, {
    submit_plan67(session, "A", "first", "run-A-first")
    submit_plan67(session, "A", "second", "run-A-second")
    resolvers[["first"]]()
    drain_plan67_loop()
    expect_identical(entered, c("first", "second"))

    session$setInputs(chat_input_cancel = list(
      threadId = "A", runId = "run-A-first", ts = 2
    ))
    session$flushReact()
    drain_plan67_loop()

    expect_identical(cancel_calls[["second"]] %||% 0L, 0L)
    expect_false(cancelled[["second"]]())
    resolvers[["second"]]()
    drain_plan67_loop()
  })
})

test_that("queued cancellation removes only that run and publishes authoritative phases", {
  gate <- new_plan67_gate()
  sent <- list()
  provider_projects <- character()
  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = gate$handler, max_concurrent_runs = 1L,
      working_dir = "/project-default",
      git_branch_provider = function(project) {
        provider_projects <<- c(provider_projects, project)
        "feature/queued"
      }
    )
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "first", "run-A", project = "/project-A")
    submit_plan67(session, "B", "first", "run-B", project = "/project-B")
    session$setInputs(chat_input_cancel = list(threadId = "B", runId = "run-B", ts = 1))
    session$flushReact()
    drain_plan67_loop()
    expect_identical(provider_projects, "/project-B")
    gate$release("A:first")
    drain_plan67_loop()

    expect_identical(gate$entered(), "A:first")
    phases <- Filter(function(x) identical(x$type, "chat_input:run-state"), sent)
    b_phases <- vapply(Filter(function(x) identical(x$message$threadId, "B"), phases),
                       function(x) x$message$phase, character(1))
    expect_true("queued" %in% b_phases)
    expect_true("cancelled" %in% b_phases)
  })
})

test_that("Claude handler advertises cross-thread concurrency capability", {
  skip_if_not_installed("ClaudeAgentSDK")
  handler <- make_claude_handler(session_map_path = tempfile(fileext = ".rds"))
  expect_true(isTRUE(attr(handler, "supports_concurrent_threads")))
})


test_that("approval waits are isolated and cancelling A does not settle B", {
  approvals <- list()
  entered <- character()
  handler <- function(thread_id, wait_for_approval, on_done, ...) {
    entered <<- c(entered, thread_id)
    promises::then(
      wait_for_approval(paste0("tool-", thread_id)),
      onFulfilled = function(value) {
        approvals[[thread_id]] <<- value
        on_done()
        NULL
      }
    )
  }
  attr(handler, "supports_concurrent_threads") <- TRUE
  sent <- list()

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 2L)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "approval", "run-A-approval")
    submit_plan67(session, "B", "approval", "run-B-approval")
    expect_setequal(entered, c("A", "B"))
    expect_length(approvals, 0L)

    session$setInputs(chat_input_tool_approval = list(
      toolCallId = "tool-B", approved = TRUE, ts = 1
    ))
    session$flushReact()
    drain_plan67_loop()
    expect_true(isTRUE(approvals$B$approved))
    expect_null(approvals$A)

    session$setInputs(chat_input_cancel = list(
      threadId = "A", runId = "run-A-approval", ts = 2
    ))
    session$flushReact()
    drain_plan67_loop()
    expect_false(isTRUE(approvals$A$approved))

    phases <- Filter(function(x) identical(x$type, "chat_input:run-state"), sent)
    phase_for <- function(thread_id) vapply(
      Filter(function(x) identical(x$message$threadId, thread_id), phases),
      function(x) x$message$phase, character(1)
    )
    expect_true("cancelled" %in% phase_for("A"))
    expect_false("complete" %in% phase_for("A"))
    expect_true("complete" %in% phase_for("B"))
  })
})


test_that("a thrown handler releases its permit exactly once for the next thread", {
  entered <- character()
  handler <- function(message, thread_id, on_done, ...) {
    entered <<- c(entered, thread_id)
    if (identical(thread_id, "A")) stop("expected failure")
    on_done()
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 1L)
  }, {
    submit_plan67(session, "A", "fail", "run-A-fail")
    submit_plan67(session, "B", "continue", "run-B-continue")
    drain_plan67_loop()
    expect_identical(entered, c("A", "B"))
  })
})


test_that("max_concurrent_runs validates and clamps at the package ceiling", {
  expect_error(.normalize_max_concurrent_runs(0), "positive integer")
  expect_error(.normalize_max_concurrent_runs(1.5), "positive integer")
  expect_error(.normalize_max_concurrent_runs(NA_real_), "positive integer")
  expect_error(.normalize_max_concurrent_runs("2"), "positive integer")
  expect_identical(.normalize_max_concurrent_runs(99L), 8L)

  safe <- function(...) NULL
  attr(safe, "supports_concurrent_threads") <- TRUE
  expect_identical(.effective_max_concurrent_runs(safe, 99L), 8L)
  attr(safe, "supports_concurrent_threads") <- NULL
  expect_identical(.effective_max_concurrent_runs(safe, 8L), 1L)
})


test_that("session close cancels queued runs without entering their handlers", {
  gate <- new_plan67_gate()
  sent <- list()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = gate$handler, max_concurrent_runs = 1L)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "active", "run-A-active")
    submit_plan67(session, "B", "queued", "run-B-queued")
    expect_identical(gate$entered(), "A:active")
    session$close()
    drain_plan67_loop()
    expect_identical(gate$entered(), "A:active")
    b_phases <- vapply(
      Filter(function(x) identical(x$type, "chat_input:run-state") &&
               identical(x$message$threadId, "B"), sent),
      function(x) x$message$phase, character(1)
    )
    expect_true("cancelled" %in% b_phases)
  })
})


test_that("active cancel emits a settled done and the same thread can run again", {
  entered <- character()
  cancel_active <- NULL
  sent <- list()
  handler <- function(message, thread_id, on_done, register_cancel, ...) {
    entered <<- c(entered, message)
    if (identical(message, "first")) {
      return(promises::promise(function(resolve, reject) {
        register_cancel(function() {
          resolve(NULL)
          invisible(NULL)
        })
      }))
    }
    on_done()
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, max_concurrent_runs = 2L)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "first", "run-A-first")
    session$setInputs(chat_input_cancel = list(
      threadId = "A", runId = "run-A-first", ts = 1
    ))
    session$flushReact(); drain_plan67_loop()
    cancelled_done <- Filter(function(x) {
      identical(x$type, "chat_input:done") &&
        identical(x$message$runId, "run-A-first") &&
        isTRUE(x$message$cancelled)
    }, sent)
    expect_length(cancelled_done, 1L)

    submit_plan67(session, "A", "second", "run-A-second")
    expect_identical(entered, c("first", "second"))
  })
})


test_that("run stages are additive and metadata cannot start streaming", {
  sent <- list()
  handler <- function(message, on_chunk, on_done, on_warming, on_commands,
                      on_usage, on_status, on_run_phase) {
    on_run_phase("sending")
    on_warming(FALSE)
    on_commands(list(), list())
    on_usage(tokens = 1L)
    on_status("init", "Initializing")
    on_chunk("one")
    on_chunk("two")
    on_run_phase("finalizing")
    on_done()
  }
  attr(handler, "supports_concurrent_threads") <- TRUE

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    submit_plan67(session, "A", "stages", "run-stages")
    drain_plan67_loop()
    expect_true(any(vapply(
      sent, function(item) identical(item$type, "chat_input:done"), logical(1)
    )))

    states <- lapply(Filter(
      function(item) identical(item$type, "chat_input:run-state"), sent
    ), `[[`, "message")
    running_stream <- Filter(function(state) {
      identical(state$phase, "running") && identical(state$stage, "streaming")
    }, states)
    expect_length(running_stream, 1L)
    expect_true(any(vapply(states, function(state) {
      identical(state$phase, "connecting") && identical(state$stage, "sending")
    }, logical(1))))
    expect_true(any(vapply(states, function(state) {
      identical(state$phase, "running") && identical(state$stage, "finalizing")
    }, logical(1))))
    expect_identical(states[[length(states)]]$phase, "complete")
    expect_null(states[[length(states)]]$stage)
  })
})


test_that("archiving settles an approval registered after foreground completion", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  decision <- NULL
  handler <- function(on_done, on_tool_call, wait_for_approval, ...) {
    on_done()
    later::later(function() {
      on_tool_call(
        "approval-after-done", "Bash", list(command = "echo pending"),
        list(requiresApproval = TRUE)
      )
      promises::then(
        wait_for_approval("approval-after-done"),
        function(value) decision <<- value
      )
    }, delay = 0.02)
    invisible(NULL)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler,
      on_archive_session = function(...) invisible(NULL)
    )
  }, {
    submit_plan67(session, "A", "start", "run-A-late-approval")
    drain_plan67_loop()
    expect_null(decision)

    session$setInputs(chat_input_archive_session = list(
      sessionId = "A", archived = TRUE, ts = 1
    ))
    session$flushReact()
    drain_plan67_loop()

    expect_false(isTRUE(decision$approved))
    expect_identical(decision$toolCallId, "approval-after-done")
  })
})


test_that("session end settles an approval registered after foreground completion", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  decision <- NULL
  handler <- function(on_done, wait_for_approval, ...) {
    on_done()
    later::later(function() {
      promises::then(
        wait_for_approval("approval-after-session"),
        function(value) decision <<- value
      )
    }, delay = 0.02)
    invisible(NULL)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    submit_plan67(session, "A", "start", "run-A-session-approval")
    drain_plan67_loop()
    expect_null(decision)

    session$close()
    drain_plan67_loop()

    expect_false(isTRUE(decision$approved))
    expect_identical(decision$toolCallId, "approval-after-session")
  })
})
