plan123_temp_home <- function() {
  home <- tempfile("plan123-home-")
  dir.create(home, mode = "0700")
  home
}

plan123_memory_config <- function() list(
  enabled = TRUE,
  soft_pss_bytes = 100,
  hard_pss_bytes = 200,
  soft_rss_bytes = 125,
  hard_rss_bytes = 225,
  consecutive_samples = 2L,
  hysteresis = 0.8,
  active_interval = 1,
  idle_interval = 5,
  settle_delay = 2
)

test_that("Plan 123 settings default on and valid false values are retained", {
  defaults <- shinyAssistantUI:::.addin_settings_defaults()
  expect_true(defaults$diagnosticsEnabled)
  expect_true(defaults$showPerformanceOrb)

  path <- tempfile(fileext = ".json")
  on.exit(unlink(path, force = TRUE), add = TRUE)
  writeLines('{"diagnosticsEnabled":false,"showPerformanceOrb":false,"unknown":{"keep":1}}', path)
  doc <- shinyAssistantUI:::.read_addin_settings_document(path)
  expect_identical(doc$classification, "valid")
  expect_false(doc$settings$diagnosticsEnabled)
  expect_false(doc$settings$showPerformanceOrb)
  expect_identical(doc$revisions$diagnosticsEnabled, 0)
})

test_that("Plan 123 settings malformed bytes are fail-safe and immutable", {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path, force = TRUE), add = TRUE)
  bytes <- charToRaw('{"diagnosticsEnabled":true,"diagnosticsEnabled":false}')
  con <- file(path, "wb"); writeBin(bytes, con); close(con)
  before <- readBin(path, "raw", n = file.info(path)$size)

  doc <- shinyAssistantUI:::.read_addin_settings_document(path)
  expect_identical(doc$classification, "malformed")
  expect_false(doc$settings$diagnosticsEnabled)
  expect_true(doc$settings$showPerformanceOrb)
  result <- shinyAssistantUI:::.transact_addin_setting(
    "showPerformanceOrb", 0, FALSE, path = path
  )
  expect_identical(result$category, "malformed_document")
  after <- readBin(path, "raw", n = file.info(path)$size)
  expect_identical(after, before)
})

test_that("Plan 123 field CAS materializes v2 and preserves other and unknown fields", {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(c(path, paste0(path, ".settings.lock")), recursive = TRUE, force = TRUE), add = TRUE)
  writeLines('{"composerDensity":"compact","unknown":{"keep":1}}', path)

  first <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 0, FALSE, path = path
  )
  expect_identical(first$category, "ok")
  expect_identical(first$revision, 1)
  second <- shinyAssistantUI:::.transact_addin_setting(
    "showPerformanceOrb", 0, FALSE, path = path
  )
  expect_identical(second$category, "ok")
  stale <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 0, TRUE, path = path
  )
  expect_identical(stale$category, "stale_revision")
  expect_false(stale$value)

  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  expect_identical(raw$unknown$keep, 1L)
  expect_identical(raw$composerDensity, "compact")
  expect_identical(raw$`_settingsV2`$version, 2L)
  expect_named(raw$`_settingsV2`$revisions,
               shinyAssistantUI:::.addin_settings_fields(), ignore.order = FALSE)
  expect_identical(raw$`_settingsV2`$revisions$diagnosticsEnabled, 1L)
  expect_identical(raw$`_settingsV2`$revisions$showPerformanceOrb, 1L)
})

test_that("Plan 123 launch contract captures presence, source, revision and ignores later env", {
  settings <- shinyAssistantUI:::.addin_settings_defaults()
  settings$diagnosticsEnabled <- FALSE
  settings$showPerformanceOrb <- TRUE
  revisions <- setNames(as.list(rep(0, 9)), shinyAssistantUI:::.addin_settings_fields())
  revisions$diagnosticsEnabled <- 4
  revisions$showPerformanceOrb <- 2

  captured <- shinyAssistantUI:::.capture_addin_launch_contract(
    settings, revisions,
    diagnostics_env = "", diagnostics_dir_env = "/PRIVATE/IGNORED"
  )
  expect_identical(captured$launch_contract_version, 2L)
  expect_identical(captured$captured_addin$diagnostics, list(
    present = TRUE, value = FALSE, source = "persisted", revision = 4
  ))
  expect_identical(captured$captured_addin$showPerformanceOrb, list(
    present = TRUE, value = TRUE, source = "persisted", revision = 2
  ))
  withr::local_envvar(SHINYASSISTANTUI_DIAGNOSTICS = "on")
  resolved <- shinyAssistantUI:::.resolve_addin_launch_contract(captured)
  expect_false(resolved$diagnostics$enabled)
  expect_true(resolved$showPerformanceOrb)

  changed <- captured
  changed$captured_addin$diagnostics$value <- TRUE
  expect_false(identical(
    shinyAssistantUI:::.claude_bg_request_fingerprint(list(project = "/p", launch = captured)),
    shinyAssistantUI:::.claude_bg_request_fingerprint(list(project = "/p", launch = changed))
  ))
})

test_that("Plan 123 canonical diagnostics schema rejects identifiers and emits exact rows", {
  schema <- shinyAssistantUI:::.diagnostics_schema()
  expect_identical(schema$artifactVersion, 1L)
  expect_true("memory_guard_sample" %in% names(schema$events))
  row <- shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 2, bytes = 8), now = function() 123
  )
  expect_named(row, c("schema", "event", "ts", "metrics"))
  expect_identical(row$ts, 123)
  expect_named(row$metrics, c("count", "bytes"))
  expect_null(shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 2, bytes = 8, path = "/PRIVATE"),
    now = function() 123
  ))
  encoded <- shinyAssistantUI:::.diagnostics_canonical_encode(row)
  expect_identical(encoded, '{"schema":1,"event":"chunk_summary","ts":123,"metrics":{"count":2,"bytes":8}}\n')
  expect_false(grepl("pid|threadId|runId|path|source", encoded))
})

test_that("Plan 123 diagnostics callback path only coalesces, enqueues and arms one shot", {
  root <- tempfile("plan123-diagnostics-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  scheduled <- list()
  schedule <- function(callback, delay) {
    scheduled[[length(scheduled) + 1L]] <<- callback
    function() NULL
  }
  service <- shinyAssistantUI:::.new_diagnostics_service(
    list(enabled = TRUE, directory = root),
    writer_factory = shinyAssistantUI:::.new_diagnostics_writer,
    schedule = schedule
  )
  on.exit(service$close(), add = TRUE)
  expect_true(service$emit("chunk_summary", list(count = 1, bytes = 4)))
  expect_true(service$emit("chunk_summary", list(count = 2, bytes = 8)))
  expect_length(scheduled, 1L)
  expect_false(dir.exists(root) && length(list.files(root, pattern = "\\.jsonl$")) > 0L)
  scheduled[[1L]]()
  expect_true(dir.exists(root))
  expect_length(list.files(root, pattern = "^diag-v1-.*\\.jsonl$"), 1L)
  expect_identical(service$snapshot()$active_bindings, 0L)
})

test_that("Plan 123 retention deletes old inactive candidates but protects active legacy", {
  root <- tempfile("plan123-retention-")
  dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  old_epoch <- 1000000000000
  old <- file.path(root, sprintf("diag-v1-%013.0f-%s.jsonl", old_epoch, strrep("a", 32)))
  writeLines('{"schema":1,"event":"frontend_mount","ts":1,"metrics":{}}', old)
  legacy <- file.path(root, sprintf(
    "diagnostics-g_a-s_b-p%d-u_c.jsonl", Sys.getpid()
  ))
  writeLines("legacy", legacy)
  result <- shinyAssistantUI:::.diagnostics_retention_pass(
    root, now = as.POSIXct("2026-09-15", tz = "UTC"), max_bytes = 50 * 1024^2
  )
  expect_false(file.exists(old))
  expect_true(file.exists(legacy))
  expect_gte(result$deleted_count, 1)
})

test_that("Plan 123 memory hub advertises v3 and preserves exact v2 opening freeze", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(plan123_memory_config())
  on.exit(plugin$dispose(), add = TRUE)
  session <- shiny::MockShinySession$new()
  sent <- list()
  session$sendCustomMessage <- function(type, message) {
    sent[[length(sent) + 1L]] <<- list(type = type, message = message)
  }
  binding <- shiny::withReactiveDomain(session, plugin$bind(session, "chat_input"))
  session$flushReact()
  expect_identical(binding$config$version, 3L)
  owner <- binding$config$ownerSeed
  plugin$observe(list(pss_bytes = 80, rss_bytes = 90), "normal", "normal")
  session$setInputs(chat_input_memory_monitor_visible = list(
    version = 2L, ownerId = owner, openId = 1, visible = TRUE,
    revision = 0, sample = NULL
  ))
  session$flushReact()
  expect_length(sent, 1L)
  frame <- sent[[1L]]$message
  expect_named(frame, c("version", "ownerId", "openId", "revision", "sample"))
  expect_named(frame$sample, c(
    "state", "pssBytes", "rssBytes", "treeRssBytes", "treeProcessCount",
    "cgroupCurrentBytes", "cgroupMaxBytes",
    "cgroupLimited", "softPssBytes", "hardPssBytes", "softRssBytes", "hardRssBytes"
  ))
  expect_identical(frame$sample$state, "normal")
  plugin$observe(list(pss_bytes = 160, rss_bytes = 170), "normal", "soft")
  expect_length(sent, 1L)

  # The browser must echo the exact revision of the frame accepted for this
  # owner. Lower and future echoes are inert and must not advance openId.
  for (wrong_revision in c(frame$revision - 1, frame$revision + 1)) {
    session$setInputs(chat_input_memory_monitor_visible = list(
      version = 2L, ownerId = owner, openId = 1, visible = FALSE,
      revision = wrong_revision, sample = NULL
    ))
    session$flushReact()
    session$setInputs(chat_input_memory_monitor_visible = list(
      version = 2L, ownerId = owner, openId = 2, visible = TRUE,
      revision = wrong_revision, sample = NULL
    ))
    session$flushReact()
    expect_length(sent, 1L)
  }
  session$setInputs(chat_input_memory_monitor_visible = list(
    version = 2L, ownerId = owner, openId = 1, visible = FALSE,
    revision = frame$revision, sample = NULL
  ))
  session$flushReact()
  session$setInputs(chat_input_memory_monitor_visible = list(
    version = 2L, ownerId = owner, openId = 2, visible = TRUE,
    revision = frame$revision, sample = NULL
  ))
  session$flushReact()
  expect_length(sent, 2L)
  expect_identical(sent[[2L]]$message$sample$state, "soft")
  expect_identical(sent[[2L]]$message$openId, 2)
})


test_that("Plan 123 settings lock protects live owner and recovers stale malformed owner", {
  directory <- tempfile("plan123-lock-"); dir.create(directory)
  path <- file.path(directory, "addin_settings.json")
  on.exit(unlink(directory, recursive = TRUE, force = TRUE), add = TRUE)
  live <- shinyAssistantUI:::.settings_acquire_lock(path)
  expect_true(is.list(live))
  expect_identical(
    shinyAssistantUI:::.transact_addin_setting("diagnosticsEnabled", 0, FALSE, path)$category,
    "busy"
  )
  expect_true(shinyAssistantUI:::.settings_release_lock(live))

  lock_path <- shinyAssistantUI:::.settings_lock_path(path)
  dir.create(lock_path)
  writeLines("malformed-owner", file.path(lock_path, "owner.json"))
  Sys.setFileTime(lock_path, Sys.time() - 180)
  recovered <- shinyAssistantUI:::.settings_acquire_lock(
    path, now = function() Sys.time()
  )
  expect_true(is.list(recovered))
  expect_true(shinyAssistantUI:::.settings_release_lock(recovered))
})

test_that("Plan 123 field CAS merges independent process writes and rejects ABA-stale revision", {
  skip_if_not_installed("callr")
  directory <- tempfile("plan123-process-cas-"); dir.create(directory)
  path <- file.path(directory, "addin_settings.json")
  on.exit(unlink(directory, recursive = TRUE, force = TRUE), add = TRUE)
  writeLines('{"unknown":{"keep":1}}', path)
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  transact_in_process <- function(field, expected, value) callr::r(
    function(project, path, field, expected, value) {
      devtools::load_all(project, quiet = TRUE)
      shinyAssistantUI:::.transact_addin_setting(field, expected, value, path)
    },
    args = list(project = project, path = path, field = field,
                expected = expected, value = value),
    spinner = FALSE, show = FALSE
  )
  first <- transact_in_process("showPerformanceOrb", 0, FALSE)
  second <- transact_in_process("diagnosticsEnabled", 0, FALSE)
  third <- transact_in_process("diagnosticsEnabled", 1, TRUE)
  stale <- transact_in_process("diagnosticsEnabled", 1, FALSE)
  expect_identical(vapply(list(first, second, third), `[[`, character(1), "category"),
                   rep("ok", 3L))
  expect_identical(stale$category, "stale_revision")
  expect_true(stale$value)
  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  expect_identical(raw$unknown$keep, 1L)
  expect_false(raw$showPerformanceOrb)
  expect_true(raw$diagnosticsEnabled)
  expect_identical(raw$`_settingsV2`$revisions$diagnosticsEnabled, 2L)
})


test_that("Plan 123 confirmed setting dispatch applies all current-process side effects", {
  effects <- list()
  handler <- function(...) NULL
  attr(handler, "set_default_permission_mode") <- function(value) {
    effects[[length(effects) + 1L]] <<- list("permission", value)
  }
  attr(handler, "set_run_r_enabled") <- function(value) {
    effects[[length(effects) + 1L]] <<- list("run_r", value)
  }
  copilot <- list(set_auto_start = function(value) {
    effects[[length(effects) + 1L]] <<- list("copilot", value)
  })
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
  for (field in shinyAssistantUI:::.addin_settings_fields()) {
    expect_true(shinyAssistantUI:::.apply_addin_setting_side_effect(
      field, values[[field]], handler = handler, copilot_plugins = list(copilot)
    ))
  }
  expect_identical(effects, list(
    list("copilot", FALSE), list("permission", "plan"), list("run_r", FALSE)
  ))
})


test_that("Plan 123 production launch truth is derived from the service snapshot", {
  snapshots <- 0L
  service <- list(snapshot = function() {
    snapshots <<- snapshots + 1L
    list(state = "started", enabled = TRUE)
  })
  started <- shinyAssistantUI:::.addin_diagnostics_launch_config(
    launch_values = list(diagnostics = list(enabled = TRUE)),
    diagnostics_service = service,
    captured_diagnostics = list(source = "persisted", value = TRUE),
    launch_kind = "foreground"
  )
  expect_identical(snapshots, 1L)
  expect_identical(started, list(
    version = 2L, launchEnabled = TRUE, environmentOverride = "none",
    launchKind = "foreground", writerStartup = "started"
  ))

  service$snapshot <- function() list(state = "failed", enabled = FALSE)
  expect_identical(
    shinyAssistantUI:::.addin_diagnostics_launch_config(
      list(diagnostics = list(enabled = TRUE)), service,
      list(source = "env", value = TRUE), "job"
    )$writerStartup,
    "failed"
  )
  expect_identical(
    shinyAssistantUI:::.addin_diagnostics_launch_config(
      list(diagnostics = list(enabled = FALSE)), NULL,
      list(source = "persisted", value = FALSE), "foreground"
    )$writerStartup,
    "off"
  )
})
