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

test_that("A2UI operation validation accepts v0.9.1 and rejects v1/unsafe objects", {
  expect_silent(.a2ui_validate_operations(list(
    list(version = "v0.9.1", createSurface = list(
      surfaceId = "surface-1",
      catalogId = "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json",
      sendDataModel = FALSE
    ))
  )))
  expect_error(.a2ui_validate_operations(list(
    list(version = "v1.0", createSurface = list(surfaceId = "surface-1"))
  )), "v0.9")
  expect_error(.a2ui_validate_operations(list(
    list(version = "v0.9.1", createSurface = list(
      surfaceId = "surface-1",
      catalogId = "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json",
      sendDataModel = TRUE
    ))
  )), "sendDataModel")
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
    a2ui_config <- widget_config(output$chat)$a2ui
    expect_true(isTRUE(a2ui_config$experimental))
    expect_identical(unlist(a2ui_config$wireVersions), c("v0.9.1", "v0.9"))
    expect_identical(a2ui_config$mimeType, "application/a2ui+json")
    expect_false(a2ui_config$sendDataModel)
    expect_true("Slider" %in% unlist(a2ui_config$supportedComponents))
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


test_that("A2UI action projects click-time edits only onto declared bindings", {
  sent <- list(); handled <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent <<- c(sent, list(list(type = type, payload = payload)))
  })
  handler <- function(name, context, ...) handled[[length(handled) + 1L]] <<- context
  transport <- .new_a2ui_transport(session, "chat_input", "owner", handler, now = function() 100)
  operations <- list(
    list(version = "v0.9", createSurface = list(surfaceId = "surface-form")),
    list(version = "v0.9", updateComponents = list(
      surfaceId = "surface-form", components = list(
        list(id = "root", component = "Column", children = list("email", "submit")),
        list(id = "email", component = "TextField", value = list(path = "/form/email")),
        list(id = "submit", component = "Button", text = "Submit", action = list(event = list(
          name = "submit", context = list(
            formId = "server-form",
            values = list(email = list(path = "/form/email"), accepted = list(path = "/form/accepted"))
          )
        )))
      )
    )),
    list(version = "v0.9", updateDataModel = list(
      surfaceId = "surface-form", path = "/", contents = list(
        form = list(email = "old@example.com", accepted = FALSE)
      )
    ))
  )
  transport$send("thread-form", "run-form", operations, event_id = "event-form")
  base <- list(
    transportVersion = 1L, threadId = "thread-form", surfaceId = "surface-form",
    sourceComponentId = "submit", name = "submit", epoch = 1, revision = 1
  )
  invalid <- c(base, list(
    actionId = "action-extra",
    context = list(formId = "server-form", values = list(
      email = "edited@example.com", accepted = TRUE, extra = "forged"
    ))
  ))
  expect_false(transport$handle_action(invalid))
  expect_length(handled, 0L)

  valid <- c(base, list(
    actionId = "action-valid",
    context = list(formId = "forged-form", values = list(
      email = "edited@example.com", accepted = TRUE
    ))
  ))
  expect_true(transport$handle_action(valid))
  expect_length(handled, 1L)
  expect_identical(handled[[1L]], list(
    formId = "server-form",
    values = list(email = "edited@example.com", accepted = TRUE)
  ))
})


test_that("R A2UI authority rejects missing/duplicate surfaces and permits recreate after delete", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) sent <<- c(sent, list(payload)))
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  missing <- list(list(version = "v0.9.1", updateDataModel = list(
    surfaceId = "surface-1", path = "/", value = list(x = 1)
  )))
  expect_error(transport$send("thread", "run", missing, event_id = "missing"), "missing surface")
  expect_equal(transport$checkpoint("thread")$lastAcceptedSequence, 0)

  create <- list(list(version = "v0.9.1", createSurface = list(
    surfaceId = "surface-1",
    catalogId = "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json"
  )))
  transport$send("thread", "run", create, event_id = "create")
  expect_error(transport$send("thread", "run", create, event_id = "duplicate"), "already active")
  expect_equal(transport$checkpoint("thread")$lastAcceptedSequence, 1)

  remove <- list(list(version = "v0.9.1", deleteSurface = list(surfaceId = "surface-1")))
  transport$send("thread", "run", remove, event_id = "delete")
  transport$send("thread", "run", create, event_id = "recreate")
  expect_equal(transport$checkpoint("thread")$lastAcceptedSequence, 3)
})


test_that("R A2UI validation rejects JSON object/array shape drift and non-scalar catalog IDs", {
  named_operations <- list(batch = list(
    version = "v0.9", createSurface = list(surfaceId = "surface-1")
  ))
  expect_error(.a2ui_validate_operations(named_operations), "array|plain JSON")
  named_components <- list(root = list(id = "root", component = "Text", text = "x"))
  expect_error(.a2ui_validate_operations(list(list(
    version = "v0.9", updateComponents = list(
      surfaceId = "surface-1", components = named_components
    )
  ))), "components")
  expect_error(.a2ui_validate_operations(list(list(
    version = "v0.9.1", createSurface = list(
      surfaceId = "surface-1",
      catalogId = list("https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json")
    )
  ))), "catalogId")
})

test_that("A2UI action function templates cannot hide undeclared client-controlled fields", {
  malformed <- list(node = list(call = "formatString", fixed = "server"))
  submitted <- list(node = list(forged = "client"))
  expect_false(.a2ui_project_action_context(malformed, submitted)$ok)

  valid <- list(node = list(
    call = "formatString", args = list(value = "${/name}"), returnType = "string"
  ))
  projected <- .a2ui_project_action_context(valid, list(node = "Grace"))
  expect_true(projected$ok)
  expect_identical(projected$value, list(node = "Grace"))

  duplicate <- structure(list("/name", "/other"), names = c("path", "path"))
  expect_false(.a2ui_project_action_context(list(value = duplicate), list(value = "x"))$ok)
})
