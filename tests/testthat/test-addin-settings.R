# addin_settings.json 读写 + 迁移(Plan 46)。

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
  expect_identical(bad_result, shinyAssistantUI:::.addin_settings_defaults())
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

test_that(".migrate_addin_settings folds old rds into json then deletes them; idempotent", {
  home <- tempfile("home"); dir.create(file.path(home, ".claude_addin"), recursive = TRUE)
  on.exit(unlink(home, recursive = TRUE), add = TRUE)
  P <- function(n) shinyAssistantUI:::.claude_addin_path(n, home)
  saveRDS("acceptEdits", P("default_permission_mode.rds"))
  saveRDS(list(showBypass = TRUE, showYolo = FALSE), P("mode_visibility.rds"))
  saveRDS("compact", P("composer_density.rds"))
  saveRDS(FALSE, P("run_r_enabled.rds"))
  expect_true(shinyAssistantUI:::.migrate_addin_settings(home))
  r <- shinyAssistantUI:::.read_addin_settings(shinyAssistantUI:::.addin_settings_path(home))
  expect_identical(r$defaultPermissionMode, "acceptEdits")
  expect_false(r$modeVisibility$showYolo)
  expect_identical(r$composerDensity, "compact")
  expect_false(r$runREnabled)
  expect_false(file.exists(P("default_permission_mode.rds")))  # 旧 rds 已删
  expect_false(file.exists(P("run_r_enabled.rds")))
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
