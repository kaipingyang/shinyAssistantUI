# addin_settings.json 读写 + 迁移(Plan 46)。

test_that("wire integers enforce both bounds independently of the positive flag", {
  for (positive in c(FALSE, TRUE)) {
    expect_null(.settings_safe_integer(2^53, positive = positive))
    expect_null(.settings_safe_integer(-1, positive = positive))
    expect_null(.settings_safe_integer(1.5, positive = positive))
    expect_identical(.settings_safe_integer(2^53 - 1, positive = positive), 2^53 - 1)
  }
  expect_identical(.settings_safe_integer(0), 0)
  expect_null(.settings_safe_integer(0, positive = TRUE))
})

test_that(".read/.write_addin_settings round-trip preserves copilot auto-start", {
  path <- tempfile(fileext = ".json"); on.exit(unlink(path), add = TRUE)
  s <- list(defaultPermissionMode = "bypassPermissions",
            modeVisibility = list(showBypass = FALSE, showYolo = TRUE),
            composerDensity = "compact", assistantTextSize = "small",
            runREnabled = FALSE, autoStartCopilotApi = FALSE)
  shinyAssistantUI:::.write_addin_settings(s, path)
  r <- shinyAssistantUI:::.read_addin_settings(path)
  expect_identical(r$defaultPermissionMode, "bypassPermissions")
  expect_false(r$modeVisibility$showBypass)
  expect_true(r$modeVisibility$showYolo)
  expect_identical(r$composerDensity, "compact")
  expect_identical(r$assistantTextSize, "small")
  expect_false(r$runREnabled)
  expect_false(r$autoStartCopilotApi)
  expect_match(paste(readLines(path), collapse = "\n"), "bypassPermissions", fixed = TRUE)  # 可读 JSON
})

test_that(".read_addin_settings defaults copilot auto-start on missing / bad / partial JSON", {
  missing <- shinyAssistantUI:::.read_addin_settings(tempfile(fileext = ".json"))
  expect_identical(missing, shinyAssistantUI:::.addin_settings_defaults())
  expect_true(missing$autoStartCopilotApi)

  bad <- tempfile(fileext = ".json"); writeLines("{not valid json", bad); on.exit(unlink(bad), add = TRUE)
  bad_result <- shinyAssistantUI:::.read_addin_settings(bad)
  expect_false(bad_result$diagnosticsEnabled)
  expect_true(bad_result$showPerformanceOrb)
  expect_true(bad_result$autoStartCopilotApi)

  part <- tempfile(fileext = ".json"); writeLines('{"composerDensity":"compact"}', part); on.exit(unlink(part), add = TRUE)
  r <- shinyAssistantUI:::.read_addin_settings(part)
  expect_identical(r$composerDensity, "compact")        # 有的用
  expect_identical(r$assistantTextSize, "medium")         # 新字段缺失补默认
  expect_identical(r$defaultPermissionMode, "default")  # 缺的补默认
  expect_true(r$modeVisibility$showBypass)
  expect_true(r$runREnabled)
  expect_true(r$autoStartCopilotApi)
})

test_that(".migrate_addin_settings folds private old rds into json and deletes matching inputs", {
  home <- tempfile("home"); dir.create(file.path(home, ".claude_addin"), recursive = TRUE)
  on.exit(unlink(home, recursive = TRUE), add = TRUE)
  P <- function(n) shinyAssistantUI:::.claude_addin_path(n, home)
  legacy_names <- c(
    "default_permission_mode.rds", "mode_visibility.rds",
    "composer_density.rds", "run_r_enabled.rds"
  )
  saveRDS("acceptEdits", P(legacy_names[[1L]]))
  saveRDS(list(showBypass = TRUE, showYolo = FALSE), P(legacy_names[[2L]]))
  saveRDS("compact", P(legacy_names[[3L]]))
  saveRDS(FALSE, P(legacy_names[[4L]]))
  for (name in legacy_names) Sys.chmod(P(name), "0600", use_umask = FALSE)
  expect_true(shinyAssistantUI:::.migrate_addin_settings(home))
  r <- shinyAssistantUI:::.read_addin_settings(shinyAssistantUI:::.addin_settings_path(home))
  expect_identical(r$defaultPermissionMode, "acceptEdits")
  expect_false(r$modeVisibility$showYolo)
  expect_identical(r$composerDensity, "compact")
  expect_false(r$runREnabled)
  expect_false(any(file.exists(vapply(legacy_names, P, character(1)))))
  expect_false(shinyAssistantUI:::.migrate_addin_settings(home))  # json 已存在 → no-op
})

test_that(".migrate_addin_settings no-op for brand-new user", {
  home <- tempfile("home2"); dir.create(file.path(home, ".claude_addin"), recursive = TRUE)
  on.exit(unlink(home, recursive = TRUE), add = TRUE)
  expect_false(shinyAssistantUI:::.migrate_addin_settings(home))
  expect_false(file.exists(shinyAssistantUI:::.addin_settings_path(home)))
})


test_that("assistant text size normalizes persisted and legacy values", {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)

  writeLines('{"assistantTextSize":"compact"}', path)
  expect_identical(shinyAssistantUI:::.read_addin_settings(path)$assistantTextSize, "compact")

  writeLines('{"assistantTextSize":"large"}', path)
  expect_identical(shinyAssistantUI:::.read_addin_settings(path)$assistantTextSize, "medium")

  writeLines('{"assistantTextSize":"tiny"}', path)
  expect_identical(shinyAssistantUI:::.read_addin_settings(path)$assistantTextSize, "medium")
})

test_that("assistant text size normalizer preserves canonical values and migrates Large", {
  expect_identical(shinyAssistantUI:::.normalize_assistant_text_size("small"), "small")
  expect_identical(shinyAssistantUI:::.normalize_assistant_text_size("compact"), "compact")
  expect_identical(shinyAssistantUI:::.normalize_assistant_text_size("medium"), "medium")
  expect_identical(shinyAssistantUI:::.normalize_assistant_text_size("large"), "medium")
  expect_null(shinyAssistantUI:::.normalize_assistant_text_size("tiny"))
})

test_that("assistantUIServer forwards normalized assistant text size changes", {
  observed <- NULL
  handler <- function(message, on_chunk, on_done, ...) on_done()

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      assistant_text_size = "medium",
      on_set_assistant_text_size = function(value) observed <<- value
    )
  }, {
    session$flushReact()
    session$setInputs(
      chat_input_assistant_text_size = list(value = "compact", ts = 1)
    )
    session$flushReact()
    expect_identical(observed, "compact")

    session$setInputs(
      chat_input_assistant_text_size = list(value = "large", ts = 2)
    )
    session$flushReact()
    expect_identical(observed, "medium")
  })
})


test_that("Claude edit markers default on, persist false, and reject malformed field values", {
  defaults <- shinyAssistantUI:::.addin_settings_defaults()
  expect_true(defaults$showClaudeEditsInRStudio)

  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  settings <- defaults
  settings$showClaudeEditsInRStudio <- FALSE
  shinyAssistantUI:::.write_addin_settings(settings, path)
  expect_false(
    shinyAssistantUI:::.read_addin_settings(path)$showClaudeEditsInRStudio
  )

  invalid_json <- c(
    '{"showClaudeEditsInRStudio":"false"}',
    '{"showClaudeEditsInRStudio":0}',
    '{"showClaudeEditsInRStudio":[false]}',
    '{"showClaudeEditsInRStudio":{"value":false}}',
    '{"showClaudeEditsInRStudio":null}'
  )
  for (text in invalid_json) {
    writeLines(text, path)
    expect_true(
      shinyAssistantUI:::.read_addin_settings(path)$showClaudeEditsInRStudio,
      info = text
    )
  }

  writeLines('{"showClaudeEditsInRStudio":false}', path)
  expect_false(
    shinyAssistantUI:::.read_addin_settings(path)$showClaudeEditsInRStudio
  )
})

test_that("assistantUIServer forwards Claude edit marker toggle events", {
  observed <- logical()
  handler <- function(message, on_done, ...) on_done()

  shiny::testServer(function(input, output, session) {
    assistantUIServer(
      "chat",
      handler = handler,
      show_claude_edits_in_rstudio = TRUE,
      on_toggle_claude_edits_in_rstudio = function(value) {
        observed <<- c(observed, value)
      }
    )
  }, {
    session$flushReact()
    session$setInputs(
      chat_input_show_claude_edits_in_rstudio = list(value = FALSE, ts = 1)
    )
    session$flushReact()
    session$setInputs(
      chat_input_show_claude_edits_in_rstudio = list(value = TRUE, ts = 2)
    )
    session$flushReact()
  })

  expect_identical(observed, c(FALSE, TRUE))
})


test_that("diagnostics and performance Orb default on; invalid fields fail safe", {
  defaults <- shinyAssistantUI:::.addin_settings_defaults()
  expect_true(defaults$diagnosticsEnabled)
  expect_true(defaults$showPerformanceOrb)

  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  invalid <- c(
    '{"diagnosticsEnabled":null}',
    '{"diagnosticsEnabled":"true"}',
    '{"diagnosticsEnabled":1}',
    '{"diagnosticsEnabled":[true]}',
    '{"diagnosticsEnabled":{"value":true}}'
  )
  for (text in invalid) {
    writeLines(text, path)
    expect_false(
      shinyAssistantUI:::.read_addin_settings(path)$diagnosticsEnabled,
      info = text
    )
  }
  writeLines('{"diagnosticsEnabled":true,"showPerformanceOrb":false}', path)
  settings <- shinyAssistantUI:::.read_addin_settings(path)
  expect_true(settings$diagnosticsEnabled)
  expect_false(settings$showPerformanceOrb)
})

test_that("diagnostics preference transaction commits only after CAS read-back", {
  directory <- tempfile("settings-cas-")
  dir.create(directory)
  path <- file.path(directory, "addin_settings.json")
  on.exit(unlink(directory, recursive = TRUE, force = TRUE), add = TRUE)
  initial <- shinyAssistantUI:::.read_addin_settings_document(path)
  create <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", initial$revisions$diagnosticsEnabled, FALSE, path
  )
  expect_identical(create$category, "ok")

  state <- new.env(parent = emptyenv())
  document <- shinyAssistantUI:::.read_addin_settings_document(path)
  state$v <- document$settings
  state$revisions <- document$revisions
  expect_true(shinyAssistantUI:::.persist_addin_diagnostics_setting(
    state, TRUE, path
  ))
  expect_true(state$v$diagnosticsEnabled)
  expect_identical(state$revisions$diagnosticsEnabled, 2)
  stale <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 1, FALSE, path
  )
  expect_identical(stale$category, "stale_revision")
  expect_true(stale$value)
})
