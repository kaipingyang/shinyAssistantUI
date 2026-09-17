isolated_test_config <- function(directory, ...) {
  shinyAssistantUI:::.normalize_diagnostics_config(
    c(list(enabled = TRUE, directory = directory, buffer_max_events = 1000L,
           max_file_bytes = 10485760L, retention_max_bytes = 52428800,
           retention_seconds = 604800), list(...)),
    sample_uniform = function() 0
  )
}

wait_until <- function(predicate, timeout = 5) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(predicate())) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.01)
  }
}

test_that("native secure capability is exact and fail-closed", {
  capability <- shinyAssistantUI:::.native_secure_capabilities()
  expect_named(capability, c(
    "version", "platform", "secureFs", "unixDatagram", "parentDeath", "noReplace"
  ))
  expect_identical(capability$version, 1L)
  if (identical(capability$platform, "linux")) {
    expect_true(all(unlist(capability[c(
      "secureFs", "unixDatagram", "parentDeath", "noReplace"
    )], use.names = FALSE)))
  }
})

test_that("isolated writer uses one supervised child and nonblocking bounded frames", {
  skip_if_not_installed("callr")
  skip_if_not(identical(shinyAssistantUI:::.worker_supervision_capability()$category, "ok"))
  root <- tempfile("isolated-writer-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  scheduled <- list()
  writer <- shinyAssistantUI:::.new_isolated_diagnostics_writer(
    isolated_test_config(root), schedule = function(callback, delay) {
      scheduled[[length(scheduled) + 1L]] <<- callback
      function() NULL
    }
  )
  on.exit(writer$close(), add = TRUE)
  first <- writer$snapshot()
  expect_true(first$enabled)
  expect_true(first$worker_pid > 0L)
  expect_true(first$worker_alive)
  expect_true(writer$write_event("backend", "chunk_summary", list(count = 1, bytes = 2)))
  expect_length(scheduled, 1L)
  expect_identical(writer$snapshot()$sent_frames, 0)
  expect_true(scheduled[[1L]]())
  expect_identical(writer$snapshot()$sent_frames, 1)
  expect_lte(writer$snapshot()$max_frame_bytes, 32768)
  expect_true(writer$close())
  expect_true(wait_until(function() !writer$snapshot()$worker_alive, timeout = 3))
  expect_identical(writer$snapshot()$active_descendants, 0L)
  expect_false(writer$close())
})

test_that("isolated sender drops once on would-block and never waits or retries", {
  root <- tempfile("isolated-drop-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  sends <- 0L
  writer <- shinyAssistantUI:::.new_isolated_diagnostics_writer(
    isolated_test_config(root), schedule = NULL,
    supervision_probe = function() list(category = "ok"),
    worker_factory = function(...) structure(list(
      is_alive = function() TRUE, get_pid = function() 999L,
      wait = function(...) NULL, kill = function(...) TRUE
    ), class = "fake_worker"),
    sender = function(path, bytes) {
      sends <<- sends + 1L
      list(ok = FALSE, category = "would_block", bytes = 0L)
    }, ready_wait = function(...) TRUE
  )
  on.exit(writer$close(), add = TRUE)
  expect_true(writer$write_event("backend", "chunk_summary", list(count = 1, bytes = 2)))
  started <- proc.time()[["elapsed"]]
  expect_false(writer$drain_now())
  elapsed <- proc.time()[["elapsed"]] - started
  expect_lt(elapsed, 0.05)
  expect_identical(sends, 1L)
  expect_identical(writer$snapshot()$dropped_frames, 1)
  expect_identical(writer$snapshot()$buffered_events, 0L)
})

test_that("isolated worker crash disables its owner without restart", {
  root <- tempfile("isolated-crash-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  alive <- TRUE; factories <- 0L
  worker <- list(
    is_alive = function() alive, get_pid = function() 123L,
    wait = function(...) NULL, kill = function(...) { alive <<- FALSE; TRUE }
  )
  writer <- shinyAssistantUI:::.new_isolated_diagnostics_writer(
    isolated_test_config(root), schedule = NULL,
    supervision_probe = function() list(category = "ok"),
    worker_factory = function(...) { factories <<- factories + 1L; worker },
    sender = function(path, bytes) list(ok = TRUE, category = "ok", bytes = length(bytes)),
    ready_wait = function(...) TRUE
  )
  alive <- FALSE
  expect_false(writer$write_event("backend", "chunk_summary", list(count = 1, bytes = 2)))
  expect_false(writer$snapshot()$enabled)
  expect_true(writer$close())
  expect_identical(writer$snapshot()$category, "closed")
  expect_identical(factories, 1L)
})

test_that("addin service shares one child while generic explicit writers are per-session", {
  skip_if_not_installed("callr")
  root <- tempfile("isolated-ownership-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  service <- shinyAssistantUI:::.new_diagnostics_service(isolated_test_config(root))
  unbind_a <- service$bind_session(); unbind_b <- service$bind_session()
  shared_pid <- service$snapshot()$worker_pid
  expect_true(shared_pid > 0L)
  expect_identical(service$snapshot()$active_bindings, 2L)
  expect_true(unbind_a())
  expect_true(service$snapshot()$worker_alive)
  expect_identical(service$snapshot()$worker_pid, shared_pid)
  expect_true(unbind_b())
  expect_true(service$close())

  root_a <- file.path(root, "generic-a"); root_b <- file.path(root, "generic-b")
  dir.create(root_a); dir.create(root_b)
  writer_a <- shinyAssistantUI:::.start_diagnostics_writer(isolated_test_config(root_a))$writer
  writer_b <- shinyAssistantUI:::.start_diagnostics_writer(isolated_test_config(root_b))$writer
  expect_true(is.list(writer_a)); expect_true(is.list(writer_b))
  expect_false(identical(writer_a$snapshot()$worker_pid, writer_b$snapshot()$worker_pid))
  expect_true(writer_a$close()); expect_true(writer_b$close())
  expect_identical(length(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())), 0L)
})


test_that("startup-ready failure TERM-waits then kills tree, reaps and resets", {
  root <- tempfile("isolated-startup-failure-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  events <- character(); alive <- TRUE
  worker <- list(
    is_alive = function() alive,
    get_pid = function() 999999L,
    signal = function(signal) { events <<- c(events, paste0("signal:", signal)); TRUE },
    wait = function(timeout) { events <<- c(events, paste0("wait:", timeout)); NULL },
    kill_tree = function() { events <<- c(events, "kill_tree"); alive <<- FALSE; TRUE },
    kill = function() { events <<- c(events, "kill"); alive <<- FALSE; TRUE }
  )
  expect_null(shinyAssistantUI:::.new_isolated_diagnostics_writer(
    isolated_test_config(root),
    supervision_probe = function() list(category = "ok"),
    worker_factory = function(...) worker,
    ready_wait = function(...) FALSE
  ))
  expect_identical(events[seq_len(4L)], c("signal:15", "wait:500", "kill_tree", "wait:1000"))
  expect_identical(shinyAssistantUI:::.diagnostics_callr_supervisor$references, 0L)
  expect_length(shinyAssistantUI:::.diagnostics_callr_supervisor$records, 0L)
})

test_that("startup-ready failure leaves no real child or grandchild", {
  skip_if_not_installed("processx")
  root <- tempfile("isolated-startup-leak-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  baseline <- shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())
  spawned <- integer()
  factory <- function(...) {
    processx::process$new(
      "sh", c("-c", "sleep 60 & wait"), cleanup = FALSE,
      cleanup_tree = FALSE, stdout = "/dev/null", stderr = "/dev/null"
    )
  }
  on.exit({
    for (pid in setdiff(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid()), baseline)) {
      token <- shinyAssistantUI:::.native_process_start_token(pid)
      if (!is.null(token)) shinyAssistantUI:::.native_terminate_process(pid, token, 100L)
    }
  }, add = TRUE)
  expect_null(shinyAssistantUI:::.new_isolated_diagnostics_writer(
    isolated_test_config(root),
    supervision_probe = function() list(category = "ok"),
    worker_factory = factory,
    ready_wait = function(...) { Sys.sleep(0.05); FALSE }
  ))
  expect_true(wait_until(function() {
    length(setdiff(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid()), baseline)) == 0L
  }, timeout = 3))
})


test_that("standalone supervision probe reaps and resets its supervisor", {
  skip_if_not_installed("callr")
  baseline <- shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())
  capability <- shinyAssistantUI:::.worker_supervision_capability(reset = TRUE)
  expect_true(capability$category %in% c("ok", "unsupported"))
  expect_true(wait_until(function() {
    length(setdiff(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid()), baseline)) == 0L
  }, timeout = 3))
  expect_identical(shinyAssistantUI:::.diagnostics_callr_supervisor$references, 0L)
  expect_length(shinyAssistantUI:::.diagnostics_callr_supervisor$records, 0L)
})
