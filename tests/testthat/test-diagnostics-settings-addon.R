settings_v2_fixture <- function(persist = function(value) TRUE) {
  callbacks <- list()
  plugin <- shinyAssistantUI:::.new_diagnostics_settings_addin_plugin(
    desired = FALSE, show_performance_orb = TRUE,
    launch_enabled = FALSE, environment_override = "none",
    launch_kind = "job", persist = persist,
    schedule = function(callback) {
      callbacks[[length(callbacks) + 1L]] <<- callback
      function() NULL
    }
  )
  list(
    plugin = plugin,
    drain = function() {
      while (length(callbacks)) {
        callback <- callbacks[[1L]]
        callbacks <<- callbacks[-1L]
        callback()
      }
    },
    pending = function() length(callbacks)
  )
}

bind_settings_v2 <- function(plugin, input_id) {
  session <- shiny::MockShinySession$new()
  sent <- list()
  session$sendCustomMessage <- function(type, message) {
    sent[[length(sent) + 1L]] <<- list(type = type, message = message)
  }
  binding <- shiny::withReactiveDomain(session, plugin$bind(session, input_id))
  session$flushReact()
  ready <- list(version = 2L, kind = "settings_ready", ownerId = binding$config$ownerId)
  ready_input <- list(ready); names(ready_input) <- paste0(input_id, "_diagnostics_settings_ready")
  do.call(session$setInputs, ready_input); session$flushReact()
  request <- function(message) {
    input <- list(message); names(input) <- paste0(input_id, "_diagnostics_setting")
    do.call(session$setInputs, input); session$flushReact()
  }
  list(session = session, binding = binding, sent = function() sent,
       clear = function() sent <<- list(), request = request)
}

settings_request <- function(binding, request_id, field, expected, value) list(
  version = 2L, kind = "settings_request", field = field,
  ownerId = binding$config$ownerId, requestId = request_id,
  expectedRevision = expected, value = value
)

test_that("settings addon publishes exact v2 bind config with all fields", {
  fixture <- settings_v2_fixture()
  on.exit(fixture$plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(fixture$plugin, "chat_input")
  config <- bound$binding$config
  expect_named(config, c("version", "kind", "ownerSeed", "ownerId", "fields"))
  expect_identical(config$version, 2L)
  expect_identical(config$kind, "settings_bind")
  expect_identical(config$ownerSeed, config$ownerId)
  expect_named(config$fields, shinyAssistantUI:::.addin_settings_fields())
  expect_true(config$fields$showPerformanceOrb$value)
  expect_false(config$fields$diagnosticsEnabled$value)
  expect_true(all(vapply(config$fields, function(field) {
    identical(names(field), c("value", "revision")) && identical(field$revision, 0)
  }, logical(1))))
})

test_that("different settings owners coexist and canonical update broadcasts", {
  persisted <- logical()
  fixture <- settings_v2_fixture(function(value) {
    persisted <<- c(persisted, value); TRUE
  })
  on.exit(fixture$plugin$dispose(), add = TRUE)
  a <- bind_settings_v2(fixture$plugin, "a_input")
  b <- bind_settings_v2(fixture$plugin, "b_input")
  expect_false(identical(a$binding$config$ownerId, b$binding$config$ownerId))

  a$request(settings_request(
    a$binding, 1, "diagnosticsEnabled", 0, TRUE
  ))
  expect_identical(fixture$pending(), 1L)
  expect_length(a$sent(), 0L)
  fixture$drain()
  expect_identical(persisted, TRUE)
  expect_identical(vapply(a$sent(), `[[`, character(1), "type"), c(
    "a_input:diagnostics-settings-canonical", "a_input:diagnostics-settings-result"
  ))
  expect_identical(b$sent()[[1L]]$type, "b_input:diagnostics-settings-canonical")
  result <- a$sent()[[2L]]$message
  expect_named(result, c("version", "kind", "field", "ownerId", "requestId",
                         "revision", "ok", "category", "value"))
  expect_true(result$ok)
  expect_identical(result$category, "ok")
  expect_identical(result$revision, 1)
})

test_that("settings exact parser silently drops malformed and wrong primitive inputs", {
  fixture <- settings_v2_fixture()
  on.exit(fixture$plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(fixture$plugin, "chat_input")
  good <- settings_request(bound$binding, 1, "diagnosticsEnabled", 0, TRUE)
  bad <- list(
    c(good, list(path = "/PRIVATE")),
    within(good, version <- 1L),
    within(good, ownerId <- "1"),
    within(good, expectedRevision <- -1),
    within(good, value <- "true")
  )
  for (message in bad) bound$request(message)
  expect_identical(fixture$pending(), 0L)
  expect_length(bound$sent(), 0L)
})

test_that("settings duplicate and out-of-order requests never write", {
  calls <- 0L
  fixture <- settings_v2_fixture(function(value) { calls <<- calls + 1L; TRUE })
  on.exit(fixture$plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(fixture$plugin, "chat_input")
  request <- settings_request(bound$binding, 2, "diagnosticsEnabled", 0, TRUE)
  bound$request(request); fixture$drain(); bound$clear()
  bound$request(request)
  lower <- settings_request(bound$binding, 1, "diagnosticsEnabled", 1, FALSE)
  bound$request(lower)
  expect_identical(calls, 1L)
  categories <- vapply(bound$sent(), function(item) item$message$category, character(1))
  expect_identical(categories, c("duplicate_request", "out_of_order"))
  expect_true(all(!vapply(bound$sent(), function(item) item$message$ok, logical(1))))
})

test_that("settings persistence failure preserves canonical and emits exact false result", {
  fixture <- settings_v2_fixture(function(value) FALSE)
  on.exit(fixture$plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(fixture$plugin, "chat_input")
  bound$request(settings_request(
    bound$binding, 1, "diagnosticsEnabled", 0, TRUE
  ))
  fixture$drain()
  expect_length(bound$sent(), 1L)
  result <- bound$sent()[[1L]]$message
  expect_false(result$ok)
  expect_identical(result$category, "io_error")
  expect_false(result$value)
  expect_identical(result$revision, 0)
})

test_that("settings binding and app cleanup are isolated and idempotent", {
  fixture <- settings_v2_fixture()
  a <- bind_settings_v2(fixture$plugin, "a_input")
  b <- bind_settings_v2(fixture$plugin, "b_input")
  expect_identical(fixture$plugin$snapshot()$bindings, 2L)
  a$session$close()
  expect_identical(fixture$plugin$snapshot()$bindings, 1L)
  expect_true(fixture$plugin$dispose())
  expect_false(fixture$plugin$dispose())
  expect_identical(fixture$plugin$snapshot()$bindings, 0L)
})


test_that("settings remount gets a fresh R owner and request sequence", {
  persisted <- logical()
  fixture <- settings_v2_fixture(function(value) {
    persisted <<- c(persisted, value)
    TRUE
  })
  on.exit(fixture$plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(fixture$plugin, "chat_input")
  first_owner <- bound$binding$config$ownerId

  bound$request(settings_request(
    bound$binding, 1, "diagnosticsEnabled", 0, TRUE
  ))
  fixture$drain()
  bound$clear()

  ready_input <- list(list(
    version = 2L, kind = "settings_ready", ownerId = first_owner
  ))
  names(ready_input) <- "chat_input_diagnostics_settings_ready"
  do.call(bound$session$setInputs, ready_input)
  bound$session$flushReact()

  expect_length(bound$sent(), 1L)
  expect_identical(bound$sent()[[1L]]$type, "chat_input:diagnostics-settings-bind")
  rebound <- bound$sent()[[1L]]$message
  expect_named(rebound, c("version", "kind", "ownerSeed", "ownerId", "fields"))
  expect_identical(rebound$kind, "settings_bind")
  expect_gt(rebound$ownerId, first_owner)
  expect_identical(rebound$ownerSeed, rebound$ownerId)
  expect_identical(rebound$fields$diagnosticsEnabled$value, TRUE)
  expect_identical(rebound$fields$diagnosticsEnabled$revision, 1)

  ready_input[[1L]]$ownerId <- rebound$ownerId
  do.call(bound$session$setInputs, ready_input)
  bound$session$flushReact()
  bound$clear()
  request <- list(
    version = 2L, kind = "settings_request", field = "diagnosticsEnabled",
    ownerId = rebound$ownerId, requestId = 1, expectedRevision = 1,
    value = FALSE
  )
  bound$request(request)
  fixture$drain()
  expect_identical(persisted, c(TRUE, FALSE))
  expect_identical(tail(bound$sent(), 1L)[[1L]]$message$category, "ok")
  expect_identical(fixture$plugin$snapshot()$last_owner, rebound$ownerId)
})


test_that("settings confirmed hook runs for every field only after successful CAS", {
  fields <- shinyAssistantUI:::.addin_settings_fields()
  values <- list(
    autoStartCopilotApi = FALSE,
    defaultPermissionMode = "plan",
    modeVisibility = list(showBypass = FALSE, showYolo = FALSE),
    composerDensity = "compact",
    assistantTextSize = "small",
    runREnabled = FALSE,
    showClaudeEditsInRStudio = FALSE,
    diagnosticsEnabled = FALSE,
    showPerformanceOrb = FALSE
  )
  document <- list(
    classification = "valid",
    settings = shinyAssistantUI:::.addin_settings_defaults(),
    revisions = setNames(as.list(rep(0, length(fields))), fields)
  )
  revisions <- document$revisions
  callbacks <- list()
  confirmed <- list()
  fail_next <- FALSE
  plugin <- shinyAssistantUI:::.new_addin_settings_coordinator(
    document = document,
    transact = function(field, expected_revision, value) {
      if (fail_next) {
        fail_next <<- FALSE
        return(list(category = "io_error", ok = FALSE,
                    value = document$settings[[field]], revision = revisions[[field]]))
      }
      if (!identical(expected_revision, revisions[[field]])) {
        return(list(category = "stale_revision", ok = FALSE,
                    value = document$settings[[field]], revision = revisions[[field]]))
      }
      revisions[[field]] <<- revisions[[field]] + 1
      document$settings[[field]] <<- value
      list(category = "ok", ok = TRUE, value = value,
           revision = revisions[[field]], settings = document$settings)
    },
    on_confirmed = function(field, value, transaction) {
      confirmed[[length(confirmed) + 1L]] <<- list(
        field = field, value = value, revision = transaction$revision
      )
    },
    schedule = function(callback) {
      callbacks[[length(callbacks) + 1L]] <<- callback
      function() NULL
    }
  )
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_settings_v2(plugin, "confirmed_input")
  drain <- function() while (length(callbacks)) {
    callback <- callbacks[[1L]]
    callbacks <<- callbacks[-1L]
    callback()
  }

  for (index in seq_along(fields)) {
    field <- fields[[index]]
    bound$request(settings_request(
      bound$binding, index, field, 0, values[[field]]
    ))
    drain()
  }
  expect_identical(vapply(confirmed, `[[`, character(1), "field"), fields)
  expect_true(all(vapply(confirmed, `[[`, numeric(1), "revision") == 1))

  bound$request(settings_request(
    bound$binding, length(fields) + 1L, fields[[1L]], 0, TRUE
  ))
  drain()
  fail_next <- TRUE
  bound$request(settings_request(
    bound$binding, length(fields) + 2L, fields[[2L]], 1, "default"
  ))
  drain()
  expect_length(confirmed, length(fields))
  expect_identical(
    vapply(tail(bound$sent(), 2L), function(item) item$message$category, character(1)),
    c("stale_revision", "io_error")
  )
})
