# Plan 167: the addin tells Claude to ask the user through UI cards first.

test_that("guidance prefers UI cards and splits AskUserQuestion / AskUserForm", {
  txt <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = TRUE)
  expect_match(txt, "AskUserQuestion", fixed = TRUE)
  expect_match(txt, "AskUserForm", fixed = TRUE)
  expect_match(txt, "plain-text question", fixed = TRUE)
  expect_match(txt, "1-4", fixed = TRUE)
  expect_match(txt, "proposals", ignore.case = TRUE)
  expect_match(txt, "permission", ignore.case = TRUE)
  expect_lt(nchar(txt), 2000L)

  without <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = FALSE)
  expect_match(without, "AskUserQuestion", fixed = TRUE)
  expect_false(grepl("AskUserForm", without, fixed = TRUE))
})

test_that("guidance is appended without replacing the existing prompt", {
  skip_if_not_installed("ClaudeAgentSDK")
  preset <- ClaudeAgentSDK::SystemPromptPreset(append = "Project root: /p.")
  out <- shinyAssistantUI:::.addin_append_system_prompt(preset, "Ask via UI.")
  expect_s3_class(out, "SystemPromptPreset")
  expect_identical(out$append, "Project root: /p.\n\nAsk via UI.")
  # appending twice is idempotent
  again <- shinyAssistantUI:::.addin_append_system_prompt(out, "Ask via UI.")
  expect_identical(again$append, out$append)

  empty <- shinyAssistantUI:::.addin_append_system_prompt(NULL, "Ask via UI.")
  expect_s3_class(empty, "SystemPromptPreset")
  expect_identical(empty$append, "Ask via UI.")

  expect_identical(shinyAssistantUI:::.addin_append_system_prompt("Custom prompt", "Ask via UI."),
                   "Custom prompt\n\nAsk via UI.")
  other <- structure(list(path = "/x"), class = "SystemPromptFile")
  expect_identical(shinyAssistantUI:::.addin_append_system_prompt(other, "Ask via UI."), other)
})
