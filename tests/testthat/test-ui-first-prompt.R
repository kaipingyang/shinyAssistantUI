# Plan 167: the addin tells Claude to ask the user through UI cards first.

test_that("guidance prefers UI cards and splits AskUserQuestion / AskUserForm", {
  txt <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = TRUE)
  expect_match(txt, "AskUserQuestion", fixed = TRUE)
  expect_match(txt, "AskUserForm", fixed = TRUE)
  expect_match(txt, "plain-text question", fixed = TRUE)
  expect_match(txt, "proposals", ignore.case = TRUE)
  expect_match(txt, "permission", ignore.case = TRUE)
  expect_lt(nchar(txt), 2000L)

  without <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = FALSE)
  expect_match(without, "AskUserQuestion", fixed = TRUE)
  expect_false(grepl("AskUserForm", without, fixed = TRUE))
})

test_that("forms take any multi-part question; AskUserQuestion only 1-2 small single choices", {
  txt <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = TRUE)
  expect_match(txt, "1-2 single-choice questions", fixed = TRUE)
  expect_match(txt, "at most 4 options", fixed = TRUE)
  expect_match(txt, "AskUserForm for everything else", fixed = TRUE)
  expect_match(txt, "3 or more questions", fixed = TRUE)
  expect_match(txt, "multiple selection", fixed = TRUE)
  expect_match(txt, "more than 4 options", fixed = TRUE)
  # The installed CLI does not expose AskUserQuestion's text/number kinds.
  for (g in list(txt, shinyAssistantUI:::.addin_ui_first_guidance(form_available = FALSE))) {
    expect_false(grepl("kind", g, fixed = TRUE))
    expect_false(grepl("min/max", g, fixed = TRUE))
  }
})

test_that("without the form tool every question still goes to AskUserQuestion", {
  without <- shinyAssistantUI:::.addin_ui_first_guidance(form_available = FALSE)
  expect_match(without, "AskUserQuestion for every question", fixed = TRUE)
  expect_match(without, "Split larger sets across calls", fixed = TRUE)
  expect_match(without, "Other answer for free text", fixed = TRUE)
})

test_that("the AskUserForm tool description states the same split", {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  src <- paste(readLines(script, warn = FALSE), collapse = "\n")
  expect_match(src, "3 or more questions", fixed = TRUE)
  expect_match(src, "use this form for everything else", fixed = TRUE)
  expect_match(src, "multiple selection", fixed = TRUE)
  expect_false(grepl("For one to four short multiple-choice questions", src, fixed = TRUE))
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
