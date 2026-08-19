run_later_queue <- function(seconds = 0.3) {
  deadline <- Sys.time() + seconds
  repeat {
    later::run_now(0)
    if (Sys.time() >= deadline) break
    Sys.sleep(0.01)
  }
  later::run_now(0)
  invisible(NULL)
}

test_that("historical loads warm asynchronously per thread without prewarm", {
  calls <- character()
  handler <- function(...) NULL
  attr(handler, "warmup") <- function(thread_id) {
    calls <<- c(calls, thread_id)
    invisible(NULL)
  }
  loader <- function(session_id, thread_id, send_thread) {
    send_thread(list(list(
      id = paste0("h-", session_id), role = "user",
      content = list(list(type = "text", text = session_id))
    )))
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler, on_session_load = loader, prewarm = FALSE
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1", threadId = "history-1"
    ))
    session$flushReact()
    expect_length(calls, 0L)
    run_later_queue()
    expect_identical(calls, "history-1")

    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1-again", threadId = "history-1"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(calls, "history-1")

    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s2", threadId = "history-2"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(calls, c("history-1", "history-2"))
  })
})

test_that("failed historical warmup clears state and can retry", {
  attempts <- 0L
  handler <- function(...) NULL
  attr(handler, "warmup") <- function(thread_id) {
    attempts <<- attempts + 1L
    if (attempts == 1L) stop("mock warmup failure")
    invisible(NULL)
  }
  loader <- function(session_id, thread_id, send_thread) send_thread(list())

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler, on_session_load = loader, prewarm = FALSE
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1", threadId = "retry-thread"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(attempts, 1L)

    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1-retry", threadId = "retry-thread"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(attempts, 2L)

    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1-dedup", threadId = "retry-thread"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(attempts, 2L)
  })
})

test_that("history only warms after send_thread and initial warmup still obeys prewarm", {
  calls <- character()
  handler <- function(...) NULL
  attr(handler, "warmup") <- function(thread_id) {
    calls <<- c(calls, thread_id)
    invisible(NULL)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler,
      on_session_load = function(session_id, thread_id, send_thread) NULL,
      prewarm = FALSE
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input_warmup = list(threadId = "initial-off"))
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "not-sent", threadId = "history-not-sent"
    ))
    session$flushReact()
    run_later_queue()
    expect_length(calls, 0L)
  })

  calls <- character()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, prewarm = TRUE)
  }, {
    session$flushReact()
    session$setInputs(chat_input_warmup = list(threadId = "initial-on"))
    session$flushReact()
    run_later_queue(0.5)
    expect_identical(calls, "initial-on")

    session$setInputs(chat_input_warmup = list(threadId = "ignored-second"))
    session$flushReact()
    run_later_queue(0.5)
    expect_identical(calls, "initial-on")
  })
})

test_that("independent Claude loaders preserve each other's session mappings", {
  skip_if_not_installed("ClaudeAgentSDK")
  path <- tempfile(fileext = ".rds")
  loader_a <- make_claude_session_loader(path)
  loader_b <- make_claude_session_loader(path)

  local_mocked_bindings(
    .get_claude_session_messages = function(session_id) list()
  )

  loader_a("session-a", "thread-a", function(messages) invisible(NULL))
  loader_b("session-b", "thread-b", function(messages) invisible(NULL))

  map <- readRDS(path)
  expect_identical(map$`thread-a`, "session-a")
  expect_identical(map$`thread-b`, "session-b")
  expect_length(Sys.glob(paste0(path, ".tmp-*")), 0L)
})


test_that("Claude session loader caches one converted snapshot and pages newest-first", {
  path <- tempfile(fileext = ".rds")
  reads <- 0L
  pages <- list()
  raw <- lapply(seq_len(123L), function(i) list(
    type = "user", uuid = paste0("u", i),
    message = list(content = paste0("message-", i))
  ))

  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      reads <<- reads + 1L
      raw
    }
  )

  loader <- make_claude_session_loader(path)
  capture <- function(messages, cursor = NULL, has_more = FALSE, ...) {
    pages[[length(pages) + 1L]] <<- list(
      messages = messages, cursor = cursor, has_more = has_more
    )
  }

  loader("session-1", "thread-1", capture, limit = 50L)
  loader("session-1", "thread-1", capture, cursor = 73L, limit = 50L)
  loader("session-1", "thread-1", capture, cursor = 23L, limit = 50L)

  expect_identical(reads, 1L)
  expect_length(pages[[1L]]$messages, 50L)
  expect_identical(pages[[1L]]$messages[[1L]]$id, "h-u74")
  expect_identical(pages[[1L]]$messages[[50L]]$id, "h-u123")
  expect_identical(pages[[1L]]$cursor, 73L)
  expect_true(pages[[1L]]$has_more)

  expect_length(pages[[2L]]$messages, 50L)
  expect_identical(pages[[2L]]$messages[[1L]]$id, "h-u24")
  expect_identical(pages[[2L]]$messages[[50L]]$id, "h-u73")
  expect_identical(pages[[2L]]$cursor, 23L)
  expect_true(pages[[2L]]$has_more)

  expect_length(pages[[3L]]$messages, 23L)
  expect_identical(pages[[3L]]$messages[[1L]]$id, "h-u1")
  expect_null(pages[[3L]]$cursor)
  expect_false(pages[[3L]]$has_more)
})

test_that("older history pages forward cursor and request ids without another warmup", {
  warmups <- character()
  calls <- list()
  sent <- list()
  handler <- function(...) NULL
  attr(handler, "warmup") <- function(thread_id) {
    warmups <<- c(warmups, thread_id)
    invisible(NULL)
  }
  loader <- function(session_id, thread_id, send_thread, cursor = NULL, limit = 50L) {
    calls[[length(calls) + 1L]] <<- list(cursor = cursor, limit = limit)
    send_thread(
      list(list(
        id = paste0("page-", cursor %||% "initial"), role = "user",
        content = list(list(type = "text", text = "history"))
      )),
      cursor = if (is.null(cursor)) 50L else NULL,
      has_more = is.null(cursor)
    )
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler, on_session_load = loader, prewarm = FALSE
    )
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "s1", threadId = "history-1",
      requestId = "history-initial-1"
    ))
    session$flushReact()
    run_later_queue()
    expect_identical(warmups, "history-1")

    session$setInputs(chat_input = list(
      type = "load_session_page", sessionId = "s1", threadId = "history-1",
      cursor = 50L, limit = 50L, requestId = "history-page-1"
    ))
    session$flushReact()
    run_later_queue()

    expect_length(calls, 2L)
    expect_null(calls[[1L]]$cursor)
    expect_identical(calls[[2L]], list(cursor = 50L, limit = 50L))
    expect_identical(warmups, "history-1")
    history_responses <- Filter(
      function(item) identical(item$type, "chat_input:load-thread"), sent
    )
    expect_length(history_responses, 2L)
    expect_identical(
      vapply(history_responses, function(item) item$message$requestId, character(1)),
      c("history-initial-1", "history-page-1")
    )
  })
})


test_that("history snapshot cache evicts least-recently-used sessions", {
  cache <- .new_history_snapshot_cache(2L)
  cache$set("a", list("A"))
  cache$set("b", list("B"))
  expect_identical(cache$get("a"), list("A"))
  cache$set("c", list("C"))

  expect_identical(cache$keys(), c("a", "c"))
  expect_false(cache$has("b"))
  expect_true(cache$has("a"))
  expect_true(cache$has("c"))
})


test_that("Claude session loader refreshes an appended transcript on each initial load", {
  path <- tempfile(fileext = ".rds")
  reads <- 0L
  raw <- lapply(seq_len(3L), function(i) list(
    type = "user", uuid = paste0("u", i),
    message = list(content = paste0("message-", i))
  ))

  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      reads <<- reads + 1L
      raw
    }
  )

  loader <- make_claude_session_loader(path)
  pages <- list()
  capture <- function(messages, cursor = NULL, has_more = FALSE, ...) {
    pages[[length(pages) + 1L]] <<- list(
      messages = messages, cursor = cursor, has_more = has_more
    )
  }

  loader("session-growing", "thread-growing", capture, limit = 2L)
  expect_identical(reads, 1L)
  expect_identical(
    vapply(pages[[1L]]$messages, `[[`, character(1), "id"),
    c("h-u2", "h-u3")
  )
  expect_identical(pages[[1L]]$cursor, 1L)

  raw <- c(raw, list(
    list(
      type = "user", uuid = "synthetic-task",
      message = list(content = paste0(
        "<task-notification><task-id>background-1</task-id>",
        "<status>completed</status></task-notification>"
      ))
    ),
    list(
      type = "assistant", uuid = "a4",
      message = list(content = list(list(
        type = "tool_use", id = "read-late", name = "Read",
        input = list(file_path = "functions/process_sdtm_data.R")
      )))
    ),
    list(
      type = "assistant", uuid = "thinking-only",
      message = list(content = list(list(
        type = "thinking", thinking = "Continue after the completed task"
      )))
    )
  ))

  # Reopening the session starts a new traversal and must see the appended tail.
  loader("session-growing", "thread-growing", capture, limit = 2L)
  expect_identical(reads, 2L)
  expect_identical(
    vapply(pages[[2L]]$messages, `[[`, character(1), "id"),
    c("h-u3", "h-a4")
  )
  expect_identical(pages[[2L]]$cursor, 2L)

  # Older pages remain pinned to that refreshed snapshot.
  loader("session-growing", "thread-growing", capture, cursor = 2L, limit = 2L)
  expect_identical(reads, 2L)
  expect_identical(
    vapply(pages[[3L]]$messages, `[[`, character(1), "id"),
    c("h-u1", "h-u2")
  )
})


test_that("Claude session refresh keeps the last successful snapshot on read failure", {
  path <- tempfile(fileext = ".rds")
  reads <- 0L
  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      reads <<- reads + 1L
      if (reads > 1L) stop("transient transcript read failure")
      list(list(
        type = "user", uuid = "stable-user",
        message = list(content = "last successful history")
      ))
    }
  )

  loader <- make_claude_session_loader(path)
  pages <- list()
  capture <- function(messages, ...) pages[[length(pages) + 1L]] <<- messages
  loader("session-transient", "thread-transient", capture)
  loader("session-transient", "thread-transient", capture)

  expect_identical(reads, 2L)
  expect_identical(pages[[1L]], pages[[2L]])
  expect_identical(pages[[2L]][[1L]]$id, "h-stable-user")
})


test_that("historical warmup waits until foreground runs settle", {
  entered <- character()
  finish_run <- NULL
  warmups <- character()
  handler <- function(message, thread_id, on_done, ...) {
    entered <<- c(entered, thread_id)
    promises::promise(function(resolve, reject) {
      finish_run <<- function() {
        on_done()
        resolve(NULL)
      }
    })
  }
  attr(handler, "warmup") <- function(thread_id) {
    warmups <<- c(warmups, thread_id)
    invisible(NULL)
  }
  loader <- function(session_id, thread_id, send_thread) send_thread(list())

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, on_session_load = loader)
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "hold foreground", threadId = "foreground", runId = "run-foreground"
    ))
    session$flushReact()
    run_later_queue(0.1)
    expect_identical(entered, "foreground")

    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "history", threadId = "background"
    ))
    session$flushReact()
    run_later_queue(0.2)
    expect_length(warmups, 0L)

    finish_run()
    session$flushReact()
    run_later_queue(0.3)
    expect_identical(warmups, "background")
  })
})


test_that("session close cancels pending warmup timers", {
  warmups <- character()
  handler <- function(...) NULL
  attr(handler, "warmup") <- function(thread_id) {
    warmups <<- c(warmups, thread_id)
    invisible(NULL)
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, prewarm = TRUE)
  }, {
    session$flushReact()
    session$setInputs(chat_input_warmup = list(threadId = "must-not-warm"))
    session$flushReact()
    session$close()
    run_later_queue(0.4)
    expect_length(warmups, 0L)
  })
})


test_that("deleting a thread removes its queued warmup before foreground release", {
  finish_run <- NULL
  warmups <- character()
  handler <- function(message, on_done, ...) {
    promises::promise(function(resolve, reject) {
      finish_run <<- function() { on_done(); resolve(NULL) }
    })
  }
  attr(handler, "warmup") <- function(thread_id) {
    warmups <<- c(warmups, thread_id)
    invisible(NULL)
  }
  loader <- function(session_id, thread_id, send_thread) send_thread(list())

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat", handler = handler, on_session_load = loader,
      on_delete_session = function(session_id) invisible(NULL)
    )
  }, {
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "foreground", threadId = "foreground", runId = "run-foreground"
    ))
    session$flushReact(); run_later_queue(0.1)
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "history", threadId = "history"
    ))
    session$flushReact(); run_later_queue(0.1)
    session$setInputs(chat_input_delete_session = list(
      sessionId = "history", ts = 1
    ))
    session$flushReact()
    finish_run(); session$flushReact(); run_later_queue(0.3)
    expect_length(warmups, 0L)
  })
})


test_that("Claude session loader routes Workspace history by project directory", {
  path <- tempfile(fileext = ".rds")
  reads <- list()
  local_mocked_bindings(
    .get_claude_session_messages = function(session_id, directory = NULL) {
      reads[[length(reads) + 1L]] <<- list(
        session_id = session_id, directory = directory
      )
      suffix <- basename(directory %||% "global")
      list(list(
        type = "user", uuid = paste0("user-", suffix),
        message = list(content = paste("history from", suffix))
      ))
    }
  )

  loader <- make_claude_session_loader(path)
  capture <- function(messages, ...) messages
  project_a <- file.path(tempdir(), "workspace-history-a")
  project_b <- file.path(tempdir(), "workspace-history-b")

  page_a <- loader("shared-session", "thread-a", capture, project = project_a)
  page_b <- loader("shared-session", "thread-b", capture, project = project_b)

  expect_identical(
    vapply(reads, `[[`, character(1), "directory"),
    c(project_a, project_b)
  )
  expect_identical(page_a[[1L]]$id, "h-user-workspace-history-a")
  expect_identical(page_b[[1L]]$id, "h-user-workspace-history-b")
  expect_length(reads, 2L)
})
