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


test_that("A2UI capabilities advertise the bundled subset catalog exactly", {
  catalog_path <- system.file(
    "schema", "a2ui", "shinyassistantui-v1-catalog.json",
    package = "shinyAssistantUI"
  )
  if (!nzchar(catalog_path)) catalog_path <- file.path(
    "inst", "schema", "a2ui", "shinyassistantui-v1-catalog.json"
  )
  expect_true(file.exists(catalog_path))
  catalog <- jsonlite::fromJSON(catalog_path, simplifyVector = FALSE)
  expect_identical(catalog$catalogId, "urn:shinyassistantui:a2ui:catalog:v1")
  expect_setequal(names(catalog$components), c(
    "Text", "Image", "Icon", "Row", "Column", "List", "Card", "Divider",
    "Button", "TextField", "CheckBox", "ChoicePicker", "DateTimeInput", "Slider"
  ))
  expect_true("text" %in% names(catalog$components$Text$properties))
  expect_true("action" %in% names(catalog$components$Button$properties))
  expect_true("value" %in% names(catalog$components$TextField$properties))
  expect_true(all(c("min", "max", "steps") %in%
    names(catalog$components$Slider$properties)))
  expect_identical(names(catalog$functions), "openUrl")
})

test_that("assistantUIServer validates and routes standard A2UI renderer errors", {
  errors <- list(); controls <- NULL
  shiny::testServer(function(input, output, session) {
    controls <<- assistantUIServer(
      "chat", handler = function(...) NULL,
      a2ui_action_handler = function(...) NULL,
      a2ui_error_handler = function(code, thread_id, surface_id, path, message, ...) {
        errors[[length(errors) + 1L]] <<- list(
          code = code, thread_id = thread_id, surface_id = surface_id,
          path = path, message = message
        )
      }
    )
  }, {
    session$flushReact()
    capabilities <- controls$a2ui_capabilities()
    expect_identical(
      unlist(capabilities$supportedCatalogIds),
      "urn:shinyassistantui:a2ui:catalog:v1"
    )
    controls$send_a2ui(
      list(list(
        version = "v0.9.1",
        createSurface = list(
          surfaceId = "surface-1",
          catalogId = "urn:shinyassistantui:a2ui:catalog:v1"
        )
      )),
      thread_id = "thread-1", run_id = "run-1", event_id = "create-1"
    )
    session$setInputs(chat_input_a2ui_error = list(
      transportVersion = 1L, threadId = "thread-1", version = "v0.9.1",
      error = list(
        code = "VALIDATION_FAILED", surfaceId = "surface-1",
        path = "/operations/0", message = "Unsupported component."
      )
    ))
    session$flushReact(); later::run_now(0.01)
    expect_length(errors, 1L)
    expect_identical(errors[[1L]], list(
      code = "VALIDATION_FAILED", thread_id = "thread-1",
      surface_id = "surface-1", path = "/operations/0",
      message = "A2UI envelope failed renderer validation."
    ))
    session$setInputs(chat_input_a2ui_error = list(
      transportVersion = 1L, threadId = "thread-1", version = "v0.9.1",
      error = list(
        code = "VALIDATION_FAILED", surfaceId = "unknown-surface",
        path = "/operations", message = "forged"
      )
    ))
    session$flushReact(); later::run_now(0.01)
    expect_length(errors, 1L)
    session$setInputs(chat_input_a2ui_error = list(
      transportVersion = 1L, threadId = "thread-1", version = "v0.9.1",
      error = list(
        code = "VALIDATION_FAILED", surfaceId = "surface-1",
        path = "relative", message = "forged", extra = TRUE
      )
    ))
    session$flushReact(); later::run_now(0.01)
    expect_length(errors, 1L)
  })
})


test_that("A2UI renderer error path is bounded and callback failures are isolated", {
  message <- list(
    transportVersion = 1L, threadId = "thread-1", version = "v0.9.1",
    error = list(
      code = "VALIDATION_FAILED", surfaceId = "surface-1",
      path = paste0("/", strrep("x", 1024)), message = "Invalid surface."
    )
  )
  expect_false(.a2ui_handle_renderer_error(
    function(...) NULL, message, function(...) TRUE
  ))
  message$error$path <- "/operations"
  expect_false(.a2ui_handle_renderer_error(
    function(...) stop("callback failed"), message, function(...) TRUE
  ))
})


test_that("display-only A2UI controller still exposes renderer capabilities", {
  controls <- NULL
  shiny::testServer(function(input, output, session) {
    controls <<- assistantUIServer("chat", handler = function(...) NULL)
  }, {
    capabilities <- controls$a2ui_capabilities()
    expect_identical(
      unlist(capabilities$supportedCatalogIds),
      "urn:shinyassistantui:a2ui:catalog:v1"
    )
    expect_false(capabilities$sendDataModel)
    expect_false(capabilities$validationChecks)
    expect_identical(unlist(capabilities$supportedLocalFunctions), "openUrl")
  })
})


test_that("R A2UI history authority dual-reads legacy and standard present artifacts", {
  snapshot <- list(
    list(version = "v0.9", createSurface = list(surfaceId = "history-surface")),
    list(version = "v0.9", updateComponents = list(
      surfaceId = "history-surface",
      components = list(list(id = "root", component = "Text", text = "history"))
    ))
  )
  marker <- list(
    kind = "surface", schemaVersion = 1L, transportVersion = 1L,
    protocolVersion = "v0.9", surfaceId = "history-surface",
    epoch = 1, revision = 1, lastSequence = 1,
    recentEventIds = list(), snapshot = snapshot,
    snapshotDigest = .a2ui_digest(snapshot),
    anchor = list(runId = "history-run", messageId = "history-message")
  )
  checkpoint <- list(
    transportVersion = 1L, protocolVersion = "v0.9", schemaVersion = 1L,
    lastAcceptedSequence = 1, generation = 1, eventLedger = list(),
    lineage = list(list(surfaceId = "history-surface", epoch = 1, revision = 1))
  )
  legacy <- list(
    type = "generative-ui", spec = list(`$type` = "Markdown", value = "derived"),
    a2ui = marker
  )
  present <- list(
    type = "tool-call", toolCallId = "a2ui:history-surface", toolName = "present",
    args = list(`$type` = "Markdown", value = "derived"), argsText = "{}", result = list(),
    artifact = list(a2ui = snapshot, shinyA2ui = marker)
  )
  session <- list(sendCustomMessage = function(...) NULL)
  message <- function(part) list(list(
    id = "history-message", role = "assistant", content = list(part)
  ))

  for (part in list(legacy, present)) {
    transport <- .new_a2ui_transport(session, "chat_input", "owner")
    expect_true(transport$restore_authority("thread-history", message(part), checkpoint))
    expect_equal(transport$checkpoint("thread-history")$lineage, checkpoint$lineage)
  }

  missing_args <- present
  missing_args$args <- NULL
  unnamed_args <- present
  unnamed_args$args <- list("not", "an", "object")
  for (invalid in list(missing_args, unnamed_args)) {
    transport <- .new_a2ui_transport(session, "chat_input", "owner")
    expect_false(transport$restore_authority("thread-history", message(invalid), checkpoint))
    expect_equal(transport$checkpoint("thread-history")$lastAcceptedSequence, 0)
  }

  mixed_message <- list(list(
    id = "history-message", role = "assistant", content = list(present, missing_args)
  ))
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  expect_false(transport$restore_authority("thread-history", mixed_message, checkpoint))
  expect_equal(transport$checkpoint("thread-history")$lastAcceptedSequence, 0)

  poisoned <- present
  poisoned$artifact$a2ui <- list(list(
    version = "v0.9", deleteSurface = list(surfaceId = "history-surface")
  ))
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  expect_false(transport$restore_authority("thread-history", message(poisoned), checkpoint))
  expect_equal(transport$checkpoint("thread-history")$lastAcceptedSequence, 0)
})


test_that("AG-UI A2UI activity snapshots adapt bucket replacement into sequenced authority", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  activity <- function(message_id, text, replace = NULL, surface_id = "activity-surface") {
    event <- list(
      type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface",
      content = list(a2ui_operations = list(
        list(version = "v0.9.1", createSurface = list(surfaceId = surface_id)),
        list(version = "v0.9.1", updateComponents = list(
          surfaceId = surface_id,
          components = list(list(id = "root", component = "Text", text = text))
        ))
      )),
      messageId = message_id
    )
    if (!is.null(replace)) event$replace <- replace
    event
  }

  first <- transport$send_activity(
    "thread-activity", "run-activity", activity("message-a", "first"),
    event_id = "activity-event-1"
  )
  expect_equal(first$sequence, 1)
  expect_equal(first$operations[[1L]]$createSurface$surfaceId, "activity-surface")

  retry <- transport$send_activity(
    "thread-activity", "run-activity", activity("message-a", "first"),
    event_id = "activity-event-1", sequence = 1
  )
  expect_equal(retry$sequence, 1)
  expect_equal(transport$checkpoint("thread-activity")$lastAcceptedSequence, 1)
  expect_length(Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent), 2L)

  conflict <- activity("message-conflict", "first")
  expect_error(
    transport$send_activity(
      "thread-activity", "run-activity", conflict,
      event_id = "activity-event-1"
    ),
    "eventId conflict"
  )

  ignored <- transport$send_activity(
    "thread-activity", "run-activity", activity("message-a", "ignored", FALSE),
    event_id = "activity-event-ignored"
  )
  expect_null(ignored)
  expect_equal(transport$checkpoint("thread-activity")$lastAcceptedSequence, 1)
  expect_length(Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent), 2L)
  expect_error(
    transport$send_activity(
      "thread-activity", "run-activity", activity("message-a", "ignored", FALSE),
      event_id = "activity-noop-sequence", sequence = 2
    ),
    "sequence.*operations"
  )
  reused_noop <- activity("message-reused", "reused")
  expect_error(
    transport$send_activity(
      "thread-activity", "run-activity", reused_noop,
      event_id = "activity-event-ignored"
    ),
    "eventId conflict"
  )

  replacement_event <- activity("message-a", "second")
  replaced <- transport$send_activity(
    "thread-activity", "run-activity", replacement_event,
    event_id = "activity-event-2", sequence = 2
  )
  replayed_replacement <- transport$send_activity(
    "thread-activity", "run-activity", replacement_event,
    event_id = "activity-event-2"
  )
  expect_equal(replayed_replacement$sequence, 2)
  expect_equal(replaced$sequence, 2)
  expect_identical(
    vapply(replaced$operations, .a2ui_operation_kind, ""),
    c("deleteSurface", "createSurface", "updateComponents")
  )
  expect_identical(replaced$operations[[3L]]$updateComponents$components[[1L]]$text, "second")

  second_bucket <- transport$send_activity(
    "thread-activity", "run-activity", activity("message-b", "third"),
    event_id = "activity-event-3"
  )
  expect_identical(second_bucket$operations[[3L]]$updateComponents$components[[1L]]$text, "third")
  moved_last <- transport$send_activity(
    "thread-activity", "run-activity", activity("message-a", "fourth"),
    event_id = "activity-event-4"
  )
  expect_identical(moved_last$operations[[3L]]$updateComponents$components[[1L]]$text, "fourth")

  removed <- activity("message-a", "unused")
  removed$content$a2ui_operations <- list()
  fallback <- transport$send_activity(
    "thread-activity", "run-activity", removed,
    event_id = "activity-event-5"
  )
  expect_equal(fallback$sequence, 5)
  expect_identical(fallback$operations[[3L]]$updateComponents$components[[1L]]$text, "third")

  removed$messageId <- "message-b"
  deletion <- transport$send_activity(
    "thread-activity", "run-activity", removed,
    event_id = "activity-event-6"
  )
  expect_equal(deletion$sequence, 6)
  expect_identical(vapply(deletion$operations, .a2ui_operation_kind, ""), "deleteSurface")

  bad <- activity("message-c", "bad")
  bad$type <- "STATE_SNAPSHOT"
  expect_error(
    transport$send_activity("thread-activity", "run-activity", bad),
    "ACTIVITY_SNAPSHOT"
  )
  bad <- activity("message-c", "bad")
  bad$activityType <- "other"
  expect_error(
    transport$send_activity("thread-activity", "run-activity", bad),
    "a2ui-surface"
  )
})

test_that("AG-UI activity snapshot resets a surface at its latest create", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  event <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "reset",
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = "reset-surface")),
      list(version = "v0.9", updateComponents = list(
        surfaceId = "reset-surface",
        components = list(list(id = "old", component = "Text", text = "old"))
      )),
      list(version = "v0.9", createSurface = list(surfaceId = "other-surface")),
      list(version = "v0.9.1", createSurface = list(surfaceId = "reset-surface")),
      list(version = "v0.9.1", updateComponents = list(
        surfaceId = "reset-surface",
        components = list(list(id = "new", component = "Text", text = "new"))
      ))
    ))
  )
  frame <- transport$send_activity(
    "thread-reset", "run-reset", event, event_id = "reset-event"
  )
  expect_identical(
    vapply(frame$operations, .a2ui_operation_kind, ""),
    c("createSurface", "updateComponents", "createSurface")
  )
  surface_ids <- vapply(frame$operations, function(operation) {
    kind <- .a2ui_operation_kind(operation)
    operation[[kind]]$surfaceId
  }, "")
  expect_identical(surface_ids, c("reset-surface", "reset-surface", "other-surface"))
  expect_identical(
    frame$operations[[2L]]$updateComponents$components[[1L]]$text,
    "new"
  )
})

test_that("AG-UI activity bucket state commits only after the A2UI send succeeds", {
  calls <- 0L
  session <- list(sendCustomMessage = function(...) {
    calls <<- calls + 1L
    stop("send failed")
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  event <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "atomic",
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = "atomic-surface"))
    ))
  )
  expect_error(transport$send_activity("thread-atomic", "run-atomic", event), "send failed")
  event$replace <- FALSE
  expect_error(transport$send_activity("thread-atomic", "run-atomic", event), "send failed")
  expect_equal(calls, 2L)
  expect_equal(transport$checkpoint("thread-atomic")$lastAcceptedSequence, 0)
})

test_that("A2UI native and AG-UI activity sends share one eventId namespace", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  empty_activity <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "empty",
    content = list(a2ui_operations = list())
  )
  expect_error(
    transport$send_activity(
      "bad thread", "run-activity", empty_activity,
      event_id = "bad-thread-event"
    ),
    "thread/run id"
  )
  expect_error(
    transport$send_activity(
      "thread-events", "bad run", empty_activity,
      event_id = "bad-run-event"
    ),
    "thread/run id"
  )
  expect_error(
    transport$send_activity(
      "thread-events", "run-activity", empty_activity,
      event_id = "bad-sequence-event", sequence = 999
    ),
    "sequence.*operations"
  )
  expect_null(transport$send_activity(
    "thread-events", "run-activity", empty_activity,
    event_id = "r-a2ui-1-1"
  ))
  create <- list(list(
    version = "v0.9", createSurface = list(surfaceId = "native-surface")
  ))
  expect_error(
    transport$send(
      "thread-events", "run-native", create,
      event_id = "r-a2ui-1-1"
    ),
    "eventId.*activity"
  )
  generated <- transport$send("thread-events", "run-native", create)
  expect_identical(generated$eventId, "r-a2ui-1-2")

  activity <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "full",
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = "activity-surface"))
    ))
  )
  frame <- transport$send_activity(
    "thread-other", "run-activity", activity,
    event_id = "shared-event"
  )
  expect_error(
    transport$send(
      "thread-other", "run-activity", frame$operations,
      event_id = "shared-event"
    ),
    "eventId.*activity"
  )
})

test_that("AG-UI activity replay ages with the authoritative event ledger", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  activity <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "aged",
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = "aged-surface"))
    ))
  )
  first <- transport$send_activity(
    "thread-aged", "run-aged", activity, event_id = "activity-aged"
  )
  expect_equal(first$sequence, 1)
  for (index in seq_len(64L)) {
    transport$send(
      "thread-aged", "run-native",
      list(list(version = "v0.9", updateDataModel = list(
        surfaceId = "aged-surface", path = "/", contents = list(index = index)
      ))),
      event_id = paste0("native-aged-", index)
    )
  }
  replay_after_expiry <- transport$send_activity(
    "thread-aged", "run-aged", activity, event_id = "activity-aged"
  )
  expect_equal(replay_after_expiry$sequence, 66)
  expect_identical(
    vapply(replay_after_expiry$operations, .a2ui_operation_kind, ""),
    c("deleteSurface", "createSurface")
  )
})

test_that("A2UI authority restore clears stale AG-UI activity buckets", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  event <- function(message_id, surface_id) list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = message_id,
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = surface_id))
    ))
  )
  transport$send_activity(
    "thread-restore", "run-old", event("old-message", "old-surface"),
    event_id = "old-event"
  )
  empty_checkpoint <- list(
    transportVersion = 1L, protocolVersion = "v0.9", schemaVersion = 1L,
    lastAcceptedSequence = 0, generation = 0, eventLedger = list(), lineage = list()
  )
  expect_true(transport$restore_authority("thread-restore", list(), empty_checkpoint))
  fresh <- transport$send_activity(
    "thread-restore", "run-new", event("new-message", "new-surface"),
    event_id = "new-event"
  )
  surface_ids <- vapply(fresh$operations, function(operation) {
    kind <- .a2ui_operation_kind(operation)
    operation[[kind]]$surfaceId
  }, "")
  expect_identical(surface_ids, "new-surface")
})

test_that("AG-UI inactive projection rejects stale surfaces from other buckets", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, payload) {
    sent[[length(sent) + 1L]] <<- list(type = type, payload = payload)
  })
  transport <- .new_a2ui_transport(session, "chat_input", "owner")
  event <- function(message_id, surface_id, with_update = FALSE) {
    operations <- list(list(
      version = "v0.9", createSurface = list(surfaceId = surface_id)
    ))
    if (with_update) operations[[2L]] <- list(
      version = "v0.9", updateDataModel = list(
        surfaceId = surface_id, path = "/", contents = list(value = "updated")
      )
    )
    list(
      type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = message_id,
      content = list(a2ui_operations = operations)
    )
  }
  transport$send_activity(
    "thread-stale", "run-active", event("bucket-y", "surface-y"), event_id = "stale-1"
  )
  transport$send_activity(
    "thread-stale", "run-active", event("bucket-x", "surface-x"), event_id = "stale-2"
  )
  transport$send(
    "thread-stale", "run-native",
    list(list(version = "v0.9", deleteSurface = list(surfaceId = "surface-y"))),
    event_id = "stale-native-delete"
  )
  expect_error(
    transport$send_activity(
      "thread-stale", "run-inactive", event("bucket-x", "surface-x", TRUE),
      event_id = "stale-control", allow_new_surfaces = FALSE
    ),
    "active matching run"
  )
  expect_equal(transport$checkpoint("thread-stale")$lastAcceptedSequence, 3)
  expect_length(Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent), 3L)
})

test_that("assistantUIServer exposes handler and control AG-UI activity entry points", {
  event <- list(
    type = "ACTIVITY_SNAPSHOT", activityType = "a2ui-surface", messageId = "server-activity",
    content = list(a2ui_operations = list(
      list(version = "v0.9", createSurface = list(surfaceId = "server-activity-surface"))
    ))
  )
  handler <- function(message, on_ag_ui_activity, on_done, ...) {
    on_ag_ui_activity(event, event_id = "server-activity-1")
    on_done()
  }
  controls <- NULL
  shiny::testServer(function(input, output, session) {
    controls <<- assistantUIServer("chat", handler = handler)
  }, {
    sent <- list()
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "activity", threadId = "thread-server", runId = "run-server",
      attachments = list(), ts = 1
    ))
    for (i in seq_len(100L)) {
      later::run_now(0.01)
      session$flushReact()
      if (any(vapply(sent, function(frame) identical(frame$type, "chat_input:done"), logical(1)))) break
    }
    frames <- Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent)
    expect_length(frames, 1L)
    expect_equal(frames[[1L]]$message$sequence, 1)

    new_surface <- event
    new_surface$messageId <- "control-activity"
    new_surface$content$a2ui_operations[[1L]]$createSurface$surfaceId <- "control-surface"
    expect_error(
      controls$send_ag_ui_activity(
        new_surface, thread_id = "thread-server", run_id = "run-control",
        event_id = "server-activity-rejected"
      ),
      "active matching run"
    )
    expect_equal(controls$a2ui_checkpoint("thread-server")$lastAcceptedSequence, 1)
    frames <- Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent)
    expect_length(frames, 1L)

    replacement <- event
    replacement$content$a2ui_operations[[2L]] <- list(
      version = "v0.9", updateComponents = list(
        surfaceId = "server-activity-surface",
        components = list(list(id = "root", component = "Text", text = "control replacement"))
      )
    )
    controls$send_ag_ui_activity(
      replacement, thread_id = "thread-server", run_id = "run-control",
      event_id = "server-activity-2"
    )
    frames <- Filter(function(frame) identical(frame$type, "chat_input:a2ui"), sent)
    expect_length(frames, 2L)
    expect_equal(frames[[2L]]$message$sequence, 2)
  })
})
