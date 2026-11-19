# Plan 168 B1: generic AskUserForm field options.
validate <- function(fields) shinyAssistantUI:::.ask_form_validate_fields(fields)
collect <- function(spec, values, other = list()) shinyAssistantUI:::.ask_form_collect(spec, values, other)
by_id <- function(ops) {
  components <- ops[[2]]$updateComponents$components
  setNames(components, vapply(components, `[[`, "", "id"))
}

test_that("placeholder, number bounds, pattern and allow_other are validated", {
  spec <- validate(list(
    list(name = "study", type = "text", placeholder = "bgb_xxxx_101",
         pattern = "^[a-z0-9_]+$", pattern_hint = "lowercase letters, digits and _"),
    list(name = "cycle", type = "number", min = 7, max = 56, step = 7, placeholder = "28"),
    list(name = "hemo", type = "select", choices = list("IO-Solid", "Solid", "Hemo"), allow_other = TRUE)
  ))
  expect_true(is.list(spec))
  expect_identical(spec[[1]]$placeholder, "bgb_xxxx_101")
  expect_identical(spec[[1]]$pattern, "^[a-z0-9_]+$")
  expect_identical(spec[[2]]$min, 7)
  expect_identical(spec[[2]]$max, 56)
  expect_identical(spec[[2]]$step, 7)
  expect_true(spec[[3]]$allow_other)

  bad <- list(
    list(list(name = "a", type = "number", min = 5, max = 1)),
    list(list(name = "a", type = "number", step = 0)),
    list(list(name = "a", type = "number", min = "x")),
    list(list(name = "a", type = "text", pattern = "([")),
    list(list(name = "a", type = "text", pattern = strrep("a", 501))),
    list(list(name = "a", type = "select", pattern = "^x$", choices = list("x", "y"))),
    list(list(name = "a", type = "text", min = 1)),
    list(list(name = "a", type = "text", allow_other = TRUE)),
    list(list(name = "a", type = "text", placeholder = strrep("p", 201))),
    list(list(name = "a", type = "date", placeholder = "2026-01-01")),
    list(list(name = "a", type = "text", pattern = "^(?=a)")),
    list(list(name = "a", type = "text", pattern = "^(a+)\\1$")),
    list(list(name = "a", type = "text", pattern = paste0(strrep("(a)?", 9), strrep("\\1", 9)))),
    list(list(name = "a", type = "text", pattern = "\\Aabc\\z"))
  )
  for (fields in bad) expect_type(validate(fields), "character")
})

test_that("submitted values honour bounds, step, pattern and other values", {
  spec <- validate(list(
    list(name = "study", type = "text", pattern = "^[a-z0-9_]+$", pattern_hint = "lowercase letters, digits and _"),
    list(name = "cycle", type = "number", min = 7, max = 56, step = 7),
    list(name = "hemo", type = "select", choices = list("IO-Solid", "Solid"), allow_other = TRUE, required = TRUE)
  ))
  ok <- collect(spec, list(study = "bgb_test_001", cycle = "28", hemo = ""), list(hemo = " Lymphoma "))
  expect_length(ok$problems, 0L)
  expect_identical(ok$values$cycle, 28)
  expect_identical(ok$values$hemo, "Lymphoma")
  picked <- collect(spec, list(study = "a", cycle = "7", hemo = "Solid"), list(hemo = ""))
  expect_identical(picked$values$hemo, "Solid")

  bad <- collect(spec, list(study = "BGB Test", cycle = "30", hemo = ""), list(hemo = ""))
  expect_true(any(grepl("lowercase letters, digits and _", bad$problems, fixed = TRUE)))
  expect_true(any(grepl("multiple of 7", bad$problems, fixed = TRUE)))
  expect_true(any(grepl("Please fill in hemo", bad$problems, fixed = TRUE)))
  out <- collect(spec, list(study = "a", cycle = "63", hemo = "Solid"))
  expect_true(any(grepl("at most 56", out$problems, fixed = TRUE)))
  low <- collect(spec, list(study = "a", cycle = "0", hemo = "Solid"))
  expect_true(any(grepl("at least 7", low$problems, fixed = TRUE)))
})

test_that("the surface carries placeholders and an other-value input bound outside /values", {
  spec <- validate(list(
    list(name = "study", type = "text", placeholder = "bgb_xxxx_101"),
    list(name = "hemo", type = "select", label = "Tumour type",
         choices = list("IO-Solid", "Solid"), allow_other = TRUE, default = "Lymphoma")
  ))
  ops <- shinyAssistantUI:::.ask_form_surface_ops("ask-form-f1", "T", spec, "Go")
  expect_silent(shinyAssistantUI:::.a2ui_validate_operations(ops))
  ids <- by_id(ops)
  expect_identical(ids[["field-study"]]$placeholder, "bgb_xxxx_101")
  other <- ids[["other-hemo"]]
  expect_identical(other$component, "TextField")
  expect_identical(other$value$path, "/other/hemo")
  root_children <- unlist(ids[["root"]]$children)
  expect_true(match("other-hemo", root_children) == match("field-hemo", root_children) + 1L)
  context <- ids[["submit"]]$action$event$context
  expect_identical(context$other$hemo$path, "/other/hemo")
  model <- ops[[3]]$updateDataModel$value
  # A default outside the choices starts in the other-value input.
  expect_identical(model$values$hemo, "")
  expect_identical(model$other$hemo, "Lymphoma")
})

test_that("a submit routes other values through the service", {
  emitters <- shinyAssistantUI:::.new_ask_form_emitters()
  emitters$register("t1", "run-1", function(...) NULL, owner = "o")
  service <- shinyAssistantUI:::.new_ask_form_service(
    emitters, schedule = function(cb, d) function() NULL, id_factory = function() "f1")
  got <- NULL
  service$request(list(type = "ask_user_form", version = 1L, request_id = "r", thread_id = "t1",
                       title = "T", submit_label = "Go",
                       fields = list(list(name = "hemo", type = "select", choices = list("A", "B"),
                                          allow_other = TRUE))),
                  function(r) got <<- r)
  service$handle_action("ask_form.submit",
                        list(formId = "ask-form-f1", values = list(hemo = ""), other = list(hemo = "C")),
                        "t1", "ask-form-f1", on_error = function(...) NULL, owner = "o")
  expect_identical(got$status, "submitted")
  expect_identical(got$values$hemo, "C")
})

test_that("the MCP tool schema advertises the new field options", {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1")
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  props <- names(env$field_schema$properties)
  for (p in c("placeholder", "min", "max", "step", "pattern", "pattern_hint", "allow_other")) {
    expect_true(p %in% props, info = p)
  }
})

test_that("extreme numbers and adversarial patterns become form errors, quickly", {
  steps <- validate(list(list(name = "n", type = "number", step = 1e-308),
                         list(name = "m", type = "number", min = -1e308, step = 1)))
  out <- collect(steps, list(n = "1e308", m = "1e308"))
  expect_true(any(grepl("n must be a multiple", out$problems, fixed = TRUE)))
  expect_true(any(grepl("m must be a multiple", out$problems, fixed = TRUE)))

  fields <- lapply(seq_len(20), function(i) list(name = paste0("t", i), type = "text", pattern = "^(a+)+$"))
  spec <- validate(fields)
  values <- stats::setNames(rep(list(paste0(strrep("a", 3999), "!")), 20), paste0("t", 1:20))
  elapsed <- system.time(res <- collect(spec, values))[["elapsed"]]
  expect_lt(elapsed, 1)
  expect_length(res$problems, 20L)

  common <- validate(list(list(name = "d", type = "text", pattern = "^\\d{8}$", pattern_hint = "yyyymmdd")))
  expect_length(collect(common, list(d = "20261119"))$problems, 0L)
  expect_true(any(grepl("expected yyyymmdd", collect(common, list(d = "2026-11-19"))$problems, fixed = TRUE)))
})

test_that("the submitted summary shows an other value under the field label", {
  spec <- validate(list(list(name = "hemo", label = "Tumour type", type = "select",
                             choices = list("A", "B"), allow_other = TRUE)))
  ops <- shinyAssistantUI:::.ask_form_summary_ops("ask-form-f1", "T", spec, "Submitted.", list(hemo = "Lymphoma"))
  texts <- vapply(ops[[1]]$updateComponents$components, function(c) as.character(c$text %||% ""), "")
  expect_true("Tumour type: Lymphoma" %in% texts)
})

test_that("an escaped backslash before a digit is not mistaken for a backreference", {
  spec <- validate(list(list(name = "a", type = "text", pattern = "^a\\\\1$")))
  expect_true(is.list(spec))
  expect_length(collect(spec, list(a = "a\\1"))$problems, 0L)
})

test_that("patterns that would blow up TRE are rejected before compiling", {
  rejected <- c("^((a{255}){255}){255}$", "^(a{50}){3}$", "a{51}",
                paste0("^(", paste(rep("a", 25), collapse = "|"), ")+$"),
                strrep("a", 201), "(abc", "[abc")
  for (p in rejected) expect_type(validate(list(list(name = "a", type = "text", pattern = p))), "character")
  accepted <- c("^[a-z0-9_]+$", "^\\d{8}$", "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", "^([0-9]{2}-){2}[0-9]{2}$",
                "^(dev|qc)$", "^(\\d+, *)*\\d+$", "^[[:alpha:]]+$", "^(?:ab)+$")
  for (p in accepted) expect_true(is.list(validate(list(list(name = "a", type = "text", pattern = p)))), info = p)
})

test_that("the worst accepted pattern stays fast across a full form", {
  alternatives <- paste(vapply(1:19, function(k) strrep("a", k %% 9 + 1), ""), collapse = "|")
  pattern <- substr(paste0("^(", alternatives, ")+(", alternatives, ")*$"), 1, 200)
  if (!is.list(validate(list(list(name = "a", type = "text", pattern = pattern))))) {
    pattern <- paste0("^(", alternatives, ")+$")
  }
  fields <- lapply(seq_len(20), function(i) list(name = paste0("t", i), type = "text", pattern = pattern))
  spec <- validate(fields)
  expect_true(is.list(spec))
  values <- stats::setNames(rep(list(paste0(strrep("a", 499), "!")), 20), paste0("t", 1:20))
  elapsed <- system.time(res <- collect(spec, values))[["elapsed"]]
  expect_lt(elapsed, 1)
  expect_length(res$problems, 20L)
  long <- collect(spec[1], list(t1 = strrep("a", 501)))
  expect_true(any(grepl("too long", long$problems, fixed = TRUE)))
})
