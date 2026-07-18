make_test_interrupt <- function(message = "simulated viewer stop") {
  structure(
    list(message = message, call = NULL),
    class = c("interrupt", "condition")
  )
}

test_that("addin gadget treats Viewer interrupt and cancellation as normal shutdown", {
  interrupt_runner <- function(...) stop(make_test_interrupt())
  cancel_runner <- function(...) stop("User cancel", call. = FALSE)
  error_runner <- function(...) stop("real startup failure", call. = FALSE)
  stop_on_cancel <- NULL
  normal_runner <- function(..., stopOnCancel = TRUE) {
    stop_on_cancel <<- stopOnCancel
    NULL
  }

  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = interrupt_runner))
  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = cancel_runner))
  expect_null(.run_claude_gadget(NULL, NULL, run_gadget = normal_runner))
  expect_false(stop_on_cancel)
  expect_error(
    .run_claude_gadget(NULL, NULL, run_gadget = error_runner),
    "real startup failure"
  )
})

test_that("session cleanup absorbs interrupt conditions from process cleanup", {
  cleanup_calls <- 0L
  handler <- function(...) NULL
  attr(handler, "cleanup") <- function() {
    cleanup_calls <<- cleanup_calls + 1L
    stop(make_test_interrupt("processx wait interrupted"))
  }

  escaped <- FALSE
  tryCatch(
    shiny::testServer(function(input, output, session) {
      assistantUIServer("chat", handler = handler)
    }, {
      session$close()
    }),
    interrupt = function(e) escaped <<- TRUE
  )

  expect_false(escaped)
  expect_identical(cleanup_calls, 1L)
})


test_that("Claude client cleanup clears registry first, retries interrupt, and continues", {
  registry <- list()
  first_calls <- 0L
  second_calls <- 0L
  registry_was_empty <- logical()

  first <- new.env(parent = emptyenv())
  first$disconnect <- function() {
    first_calls <<- first_calls + 1L
    registry_was_empty <<- c(registry_was_empty, length(registry) == 0L)
    if (first_calls == 1L) stop(make_test_interrupt("first wait interrupted"))
    invisible(NULL)
  }
  second <- new.env(parent = emptyenv())
  second$disconnect <- function() {
    second_calls <<- second_calls + 1L
    registry_was_empty <<- c(registry_was_empty, length(registry) == 0L)
    invisible(NULL)
  }
  registry <- list(first = first, second = second)

  cleanup <- function() {
    .cleanup_claude_client_registry(
      get_clients = function() registry,
      clear_clients = function() registry <<- list()
    )
  }
  expect_no_condition(cleanup())
  expect_length(registry, 0L)
  expect_identical(first_calls, 2L)
  expect_identical(second_calls, 1L)
  expect_true(all(registry_was_empty))

  expect_no_condition(cleanup())
  expect_identical(first_calls, 2L)
  expect_identical(second_calls, 1L)
})

test_that("an interrupted connect unregisters and disconnects the partial client", {
  registry <- NULL
  disconnect_calls <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() stop(make_test_interrupt("connect interrupted"))
  client$disconnect <- function() {
    disconnect_calls <<- disconnect_calls + 1L
    invisible(NULL)
  }

  escaped <- FALSE
  tryCatch(
    .connect_registered_claude_client(
      client,
      register = function(x) registry <<- x,
      unregister = function(x) {
        if (identical(registry, x)) registry <<- NULL
      }
    ),
    interrupt = function(e) escaped <<- TRUE
  )

  expect_true(escaped)
  expect_null(registry)
  expect_identical(disconnect_calls, 1L)
})
