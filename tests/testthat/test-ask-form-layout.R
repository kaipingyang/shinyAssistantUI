# Plan 168 B2: AskUserForm sections and half-width fields.
validate <- function(fields) shinyAssistantUI:::.ask_form_validate_fields(fields)
surface <- function(fields) {
  spec <- validate(fields)
  stopifnot(is.list(spec))
  ops <- shinyAssistantUI:::.ask_form_surface_ops("ask-form-f1", "Setup", spec, "Save")
  components <- ops[[2]]$updateComponents$components
  list(ops = ops, by_id = setNames(components, vapply(components, `[[`, "", "id")))
}
kids <- function(component) unlist(component$children %||% component$child)

test_that("section and width are validated", {
  spec <- validate(list(list(name = "a", type = "text", section = "Study", width = "half")))
  expect_identical(spec[[1]]$section, "Study")
  expect_identical(spec[[1]]$width, "half")
  expect_identical(validate(list(list(name = "a", type = "text")))[[1]]$width, "full")
  expect_type(validate(list(list(name = "a", type = "text", width = "third"))), "character")
  expect_type(validate(list(list(name = "a", type = "text", section = strrep("s", 81)))), "character")
})

test_that("sections become cards in first-appearance order and keep field order", {
  s <- surface(list(
    list(name = "intro", type = "text"),
    list(name = "study", type = "text", section = "Study"),
    list(name = "hemo", type = "select", choices = list("A", "B"), section = "Attributes"),
    list(name = "dev", type = "select", choices = list("dev", "qc"), section = "Study")
  ))
  expect_silent(shinyAssistantUI:::.a2ui_validate_operations(s$ops))
  root <- kids(s$by_id[["root"]])
  expect_identical(root[1:2], c("title", "label-intro"))
  cards <- root[startsWith(root, "section-")]
  expect_identical(cards, c("section-1", "section-2"))
  expect_true(match("field-intro", root) < match("section-1", root))
  expect_identical(s$by_id[["section-1"]]$component, "Card")
  body <- kids(s$by_id[[kids(s$by_id[["section-1"]])]])
  expect_identical(body[[1]], "section-1-title")
  expect_identical(s$by_id[["section-1-title"]]$text, "Study")
  expect_true(all(c("field-study", "field-dev") %in% body))
  expect_true(match("field-study", body) < match("field-dev", body))
  expect_true("field-hemo" %in% kids(s$by_id[[kids(s$by_id[["section-2"]])]]))
  expect_identical(tail(root, 2), c("error", "actions"))
})

test_that("consecutive half-width fields share a row; a lone half field stays full", {
  s <- surface(list(
    list(name = "cutoff", type = "date", width = "half", help = "yyyy-mm-dd"),
    list(name = "archive", type = "text", width = "half"),
    list(name = "notes", type = "textarea"),
    list(name = "cycle", type = "number", width = "half")
  ))
  root <- kids(s$by_id[["root"]])
  row <- s$by_id[["pair-cutoff"]]
  expect_identical(row$component, "Row")
  expect_identical(kids(row), c("cell-cutoff", "cell-archive"))
  expect_identical(s$by_id[["cell-cutoff"]]$component, "Column")
  expect_identical(kids(s$by_id[["cell-cutoff"]]), c("label-cutoff", "field-cutoff", "help-cutoff"))
  expect_true("pair-cutoff" %in% root)
  expect_false("field-cutoff" %in% root)
  expect_true(all(c("label-cycle", "field-cycle") %in% root))
  expect_false("cell-cycle" %in% names(s$by_id))
})

test_that("half-width pairing happens inside a section", {
  s <- surface(list(
    list(name = "a", type = "text", section = "S", width = "half"),
    list(name = "b", type = "text", section = "T", width = "half"),
    list(name = "c", type = "text", section = "S", width = "half")
  ))
  body <- kids(s$by_id[[kids(s$by_id[["section-1"]])]])
  expect_true("pair-a" %in% body)
  expect_identical(kids(s$by_id[["pair-a"]]), c("cell-a", "cell-c"))
})

test_that("the MCP tool schema advertises section and width", {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1")
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  props <- env$field_schema$properties
  expect_true(all(c("section", "width") %in% names(props)))
  expect_identical(unlist(props$width$enum), c("full", "half"))
})
