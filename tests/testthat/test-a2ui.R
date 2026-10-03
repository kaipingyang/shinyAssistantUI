test_that("A2UI transport sequences, deduplicates and commits only after send", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent <<- c(sent, list(list(type = type, payload = payload)))
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  ops <- list(list(version = "v0.9", createSurface = list(surfaceId = "surface-1")))
  first <- transport$send("thread-1", "run-1", ops, event_id = "event-1")
  expect_equal(first$sequence, 1)
  expect_equal(transport$checkpoint("thread-1")$lastAcceptedSequence, 1)
  transport$send("thread-1", "run-1", ops, event_id = "event-1")
  expect_length(sent, 2)
  expect_error(
    transport$send("thread-1", "run-1", list(list(version = "v0.9", deleteSurface = list(surfaceId = "surface-1"))), event_id = "event-1"),
    "conflict"
  )
  expect_error(transport$send("thread-1", "run-1", ops, sequence = 4), "next authoritative")

  failing <- list(sendCustomMessage = function(...) stop("send failed"))
  failed <- .new_a2ui_transport(failing, "chat_input", "owner")
  expect_error(failed$send("thread-1", "run-1", ops, event_id = "event-1"), "send failed")
  expect_equal(failed$checkpoint("thread-1")$lastAcceptedSequence, 0)
})

test_that("A2UI recovery returns the complete inclusive immutable range", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent <<- c(sent, list(list(type = type, payload = payload)))
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  create <- list(list(version = "v0.9", createSurface = list(surfaceId = "surface-1")))
  update <- list(list(version = "v0.9", updateDataModel = list(surfaceId = "surface-1", path = "/", contents = list(x = 1))))
  transport$send("thread-1", "run-1", create, event_id = "event-1")
  transport$send("thread-1", "run-1", update, event_id = "event-2")
  expect_true(transport$recover(list(
    transportVersion = 1L, threadId = "thread-1", expectedSequence = 1,
    receivedSequence = 2, eventId = "event-2"
  )))
  replay <- sent[[length(sent)]]
  expect_equal(replay$type, "chat_input:a2ui-recovery")
  expect_equal(vapply(replay$payload$envelopes, `[[`, numeric(1), "sequence"), c(1, 2))

  expect_false(transport$recover(list(
    transportVersion = 1L, threadId = "thread-1", expectedSequence = 2,
    receivedSequence = 3, eventId = "event-3"
  )))
  expect_equal(sent[[length(sent)]]$type, "chat_input:a2ui-recovery-failed")
})

test_that("A2UI actions require current authoritative lineage and reject replay", {
  sent <- list()
  handled <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent <<- c(sent, list(list(type = type, payload = payload)))
  })
  handler <- function(name, input, context, thread_id, surface_id,
                      source_component_id, on_a2ui, on_error) {
    handled <<- c(handled, list(list(name = name, input = input, context = context)))
  }
  transport <- .new_a2ui_transport(session, "chat_input", "owner", handler, now = function() 100)
  ops <- list(
    list(version = "v0.9", createSurface = list(surfaceId = "surface-1")),
    list(version = "v0.9", updateComponents = list(
      surfaceId = "surface-1",
      components = list(list(
        id = "root", component = "Button", text = "Confirm",
        action = list(event = list(name = "confirm", context = list(mode = "safe")))
      ))
    ))
  )
  transport$send("thread-1", "run-1", ops, event_id = "event-1")
  action <- list(
    transportVersion = 1L, actionId = "action-1", threadId = "thread-1",
    surfaceId = "surface-1", sourceComponentId = "root", name = "confirm",
    epoch = 1, revision = 1, input = list(accepted = TRUE), context = list(mode = "safe")
  )
  expect_true(transport$handle_action(action))
  expect_length(handled, 1)
  expect_false(transport$handle_action(action))
  stale <- action; stale$actionId <- "action-2"; stale$revision <- 0
  expect_false(transport$handle_action(stale))
  expect_length(handled, 1)
})

test_that("A2UI operation validation rejects wrong versions and unsafe objects", {
  expect_error(.a2ui_validate_operations(list(
    list(version = "v0.9.1", createSurface = list(surfaceId = "surface-1"))
  )), "exact raw v0.9")
  unsafe <- list(version = "v0.9", updateDataModel = list(
    surfaceId = "surface-1", path = "/", contents = structure(list(1), names = "__proto__")
  ))
  expect_error(.a2ui_validate_operations(list(unsafe)), "plain JSON")
})


test_that("assistantUIServer exposes on_a2ui and routes authoritative actions separately", {
  action_calls <- list()
  ops <- list(
    list(version = "v0.9", createSurface = list(surfaceId = "surface-1")),
    list(version = "v0.9", updateComponents = list(
      surfaceId = "surface-1", components = list(list(
        id = "root", component = "Button", text = "Confirm",
        action = list(event = list(name = "confirm", context = list(mode = "safe")))
      ))
    ))
  )
  handler <- function(message, on_a2ui, on_done, ...) {
    on_a2ui(ops, event_id = "event-1")
    on_done()
  }
  action_handler <- function(name, input, context, thread_id, surface_id, ...) {
    action_calls[[length(action_calls) + 1L]] <<- list(
      name = name, input = input, context = context,
      thread_id = thread_id, surface_id = surface_id
    )
  }
  controls <- NULL
  shiny::testServer(function(input, output, session) {
    controls <<- assistantUIServer("chat", handler = handler, a2ui_action_handler = action_handler)
  }, {
    sent <- list()
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    expect_true(isTRUE(widget_config(output$chat)$a2ui$experimental))
    controls$send_a2ui(
      ops, thread_id = "thread-1", run_id = "run-1", event_id = "event-1"
    )
    session$flushReact()
    frames <- Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent)
    expect_length(frames, 1L)
    expect_equal(frames[[1L]]$message$sequence, 1)
    session$setInputs(chat_input_a2ui_action = list(
      transportVersion = 1L, actionId = "action-1", threadId = "thread-1",
      surfaceId = "surface-1", sourceComponentId = "root", name = "confirm",
      epoch = 1, revision = 1, input = list(accepted = TRUE), context = list(mode = "safe")
    ))
    session$flushReact(); later::run_now(0.01)
    expect_length(action_calls, 1L)
    expect_identical(action_calls[[1L]]$name, "confirm")
  })
})

test_that("server history forwards and registers an explicit A2UI checkpoint", {
  checkpoint <- list(
    transportVersion = 1L, protocolVersion = "v0.9", schemaVersion = 1L,
    lastAcceptedSequence = 0, generation = 0, eventLedger = list(), lineage = list()
  )
  loader <- function(session_id, thread_id, send_thread, ...) {
    send_thread(list(), a2ui_checkpoint = checkpoint)
  }
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = function(...) NULL, on_session_load = loader)
  }, {
    sent <- list()
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session", sessionId = "history", threadId = "history", requestId = "load-1"
    ))
    session$flushReact(); later::run_now(0.02)
    frames <- Filter(function(frame) identical(frame$type, "chat_input:load-thread"), sent)
    expect_length(frames, 1L)
    expect_identical(frames[[1L]]$message$a2uiCheckpoint, checkpoint)
  })
})
