worker_socket_fixture <- function(.env = parent.frame()) {
  port <- httpuv::randomPort()
  server <- serverSocket(port)
  on.exit(close(server), add = TRUE)
  con <- socketConnection("127.0.0.1", port, blocking = FALSE, open = "r+b")
  peer <- socketAccept(server, blocking = FALSE, open = "r+b")
  loop <- later::create_loop(parent = NULL)
  state <- new.env(parent = emptyenv())
  state$alive <- TRUE
  state$killed <- 0L
  h <- new.env(parent = emptyenv())
  h$con <- con
  kill <- function() {
    state$alive <- FALSE
    state$killed <- state$killed + 1L
    invisible(TRUE)
  }
  h$proc <- list(is_alive = function() state$alive, kill = kill, kill_tree = kill)
  withr::defer(
    {
      state$alive <- FALSE
      for (connection in list(con, peer)) try(close(connection), silent = TRUE)
      later::destroy_loop(loop)
    },
    envir = .env
  )
  send <- function(value) {
    bytes <- value
    if (is.character(value)) bytes <- charToRaw(enc2utf8(value))
    writeBin(bytes, peer)
    flush(peer)
    invisible(NULL)
  }
  run <- function(on_event) {
    observed <- new.env(parent = emptyenv())
    observed$settled <- 0L
    observed$value <- NULL
    observed$error <- NULL
    later::with_loop(loop, {
      promise <- .ca_worker_run(h, "Synthetic worker fixture", on_event)
      promises::then(promise, function(value) {
        observed$value <- value
        observed$settled <- observed$settled + 1L
        NULL
      }, function(error) {
        observed$error <- error
        observed$settled <- observed$settled + 1L
        NULL
      })
    })
    observed
  }
  drive <- function(predicate, timeout = 3) {
    deadline <- Sys.time() + timeout
    while (!isTRUE(predicate())) {
      later::run_now(0.01, loop = loop)
      if (Sys.time() > deadline) stop("Worker socket fixture did not settle")
    }
    invisible(NULL)
  }
  list(h = h, loop = loop, state = state, send = send, run = run, drive = drive)
}

test_that("remote transport errors reject while the worker is still alive", {
  fixture <- worker_socket_fixture()
  close(fixture$h$con)
  observed <- fixture$run(function(event) NULL)
  deadline <- Sys.time() + 0.2
  while (!observed$settled && Sys.time() < deadline) {
    later::run_now(0.01, loop = fixture$loop)
  }
  expect_identical(observed$settled, 1L)
  expect_s3_class(observed$error, "error")
})

test_that("remote callback errors reject rather than completing successfully", {
  fixture <- worker_socket_fixture()
  observed <- fixture$run(function(event) {
    if (event$ev == "delta") stop("Synthetic UI callback failure")
  })
  fixture$send('{"ev":"delta","t":"one"}\n{"ev":"done"}\n')
  fixture$drive(function() observed$settled > 0L)
  expect_s3_class(observed$error, "error")
  if (!is.null(observed$error)) {
    expect_match(conditionMessage(observed$error), "Synthetic UI callback failure")
  }
  expect_identical(observed$settled, 1L)
})

test_that("remote JSONL framing preserves split UTF-8 and reports malformed frames", {
  fixture <- worker_socket_fixture()
  chunks <- character()
  observed <- fixture$run(function(event) {
    if (event$ev == "delta") chunks <<- c(chunks, event$t)
  })
  frame <- charToRaw(enc2utf8('{"ev":"delta","t":"\u4e2d\u6587"}\n'))
  split <- which(frame == as.raw(0xe4))[[1L]]
  fixture$send(frame[seq_len(split)])
  later::run_now(0.05, loop = fixture$loop)
  expect_length(chunks, 0L)
  expect_identical(observed$settled, 0L)
  fixture$send(c(
    frame[seq.int(split + 1L, length(frame))],
    charToRaw('{"ev":"done"}\n')
  ))
  fixture$drive(function() observed$settled > 0L)
  expect_null(observed$error)
  expect_identical(chunks, "\u4e2d\u6587")

  malformed <- worker_socket_fixture()
  failure <- malformed$run(function(event) NULL)
  malformed$send("not-json\n")
  deadline <- Sys.time() + 0.2
  while (!failure$settled && Sys.time() < deadline) {
    later::run_now(0.01, loop = malformed$loop)
  }
  expect_identical(failure$settled, 1L)
  expect_s3_class(failure$error, "error")
})

test_that("remote batches yield before a large buffered response has been exhausted", {
  fixture <- worker_socket_fixture()
  chunks <- 0L
  at_yield <- NULL
  observed <- fixture$run(function(event) {
    if (event$ev != "delta") {
      return(invisible(NULL))
    }
    chunks <<- chunks + 1L
    if (chunks == 1L) {
      later::later(function() at_yield <<- chunks, 0, loop = fixture$loop)
    }
  })
  fixture$send(paste0(
    paste(rep('{"ev":"delta","t":"one"}', 128L), collapse = "\n"),
    '\n{"ev":"done"}\n'
  ))
  fixture$drive(function() observed$settled > 0L)
  expect_null(observed$error)
  expect_identical(chunks, 128L)
  expect_gte(at_yield, 1L)
  expect_lte(at_yield, 32L)
})

test_that("remote asynchronous approval callbacks pause dispatch and surface rejection", {
  fixture <- worker_socket_fixture()
  decide <- NULL
  events <- character()
  observed <- fixture$run(function(event) {
    events <<- c(events, event$ev)
    if (event$ev == "ask") {
      decision <- promises::promise(function(resolve, reject) decide <<- reject)
      promises::catch(decision, function(error) NULL)
      return(decision)
    }
    NULL
  })
  fixture$send('{"ev":"ask"}\n{"ev":"delta","t":"after"}\n{"ev":"done"}\n')
  fixture$drive(function() is.function(decide))
  expect_identical(events, "ask")
  expect_identical(observed$settled, 0L)
  later::with_loop(fixture$loop, decide(simpleError("Synthetic approval failure")))
  fixture$drive(function() observed$settled > 0L)
  expect_s3_class(observed$error, "error")
  if (!is.null(observed$error)) {
    expect_match(conditionMessage(observed$error), "Synthetic approval failure")
  }
})

test_that("remote stop settles once, cancels polling, and ignores late approvals", {
  fixture <- worker_socket_fixture()
  approve <- NULL
  events <- character()
  observed <- fixture$run(function(event) {
    events <<- c(events, event$ev)
    promises::promise(function(resolve, reject) approve <<- resolve)
  })
  fixture$send('{"ev":"ask"}\n')
  fixture$drive(function() is.function(approve))
  later::with_loop(fixture$loop, .ca_worker_stop(fixture$h))
  fixture$drive(function() observed$settled > 0L)
  expect_s3_class(observed$error, "error")
  expect_true(fixture$h$closed)
  expect_null(fixture$h$active_run)
  later::with_loop(fixture$loop, approve(TRUE))
  fixture$drive(function() fixture$state$killed == 1L && later::loop_empty(fixture$loop))
  expect_identical(observed$settled, 1L)
  expect_identical(events, "ask")
})

test_that("remote scheduled callbacks retain the caller promise domain", {
  fixture <- worker_socket_fixture()
  seen <- logical()
  domain <- promises::new_promise_domain(wrapSync = function(expr) {
    withr::with_options(list(aui_worker_domain = TRUE), force(expr))
  })
  observed <- promises::with_promise_domain(domain, fixture$run(function(event) {
    seen <<- c(seen, isTRUE(getOption("aui_worker_domain")))
  }))
  fixture$send('{"ev":"delta","t":"one"}\n{"ev":"done"}\n')
  fixture$drive(function() observed$settled > 0L)
  expect_null(observed$error)
  expect_identical(seen, c(TRUE, TRUE))
  expect_null(getOption("aui_worker_domain"))
})

test_that("remote handler reports errors once and keeps cancellation non-error", {
  check <- function(cancelled) {
    errors <- character()
    done <- 0L
    h <- new.env(parent = emptyenv())
    h$proc <- list(is_alive = function() TRUE)
    local_mocked_bindings(
      .ca_worker_start = function(...) h,
      .ca_worker_run = function(h, prompt, on_event) {
        on_event(list(ev = "error", m = "Synthetic worker failure"))
        promises::promise_resolve(list(ev = "done"))
      },
      .ca_worker_stop = function(...) NULL
    )
    handler <- make_codeagent_remote_handler()
    on.exit(attr(handler, "teardown")(), add = TRUE)
    settled <- FALSE
    promise <- handler(
      message = "Synthetic turn", thread_id = "worker-terminal", attachments = list(),
      on_chunk = function(...) NULL, on_done = function(...) done <<- done + 1L,
      on_error = function(message) errors <<- c(errors, message),
      on_tool_call = function(...) NULL, on_tool_result = function(...) NULL,
      on_thinking = NULL, on_image = NULL, on_artifact = NULL,
      is_cancelled = function() cancelled,
      wait_for_approval = NULL, register_cancel = NULL
    )
    promises::then(promise, function(value) {
      settled <<- TRUE
      NULL
    })
    deadline <- Sys.time() + 3
    while (!settled && Sys.time() < deadline) later::run_now(0.01)
    expect_true(settled)
    expected_errors <- character()
    if (!cancelled) expected_errors <- "Synthetic worker failure"
    expect_identical(errors, expected_errors)
    expect_identical(done, 0L)
    attr(handler, "teardown")()
  }
  check(FALSE)
  check(TRUE)
})
