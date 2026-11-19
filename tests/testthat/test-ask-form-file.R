# Plan 168 B4: AskUserForm definitions loaded from a JSON file, plus defaults.
load_script <- function(remote) {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1",
                      CLAUDE_ADDIN_FORM_URL = "ipc:///tmp/form-file-test.sock",
                      CLAUDE_ADDIN_THREAD_ID = "thread-9", .local_envir = parent.frame())
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  env$.form_remote <- remote
  env
}
capture <- function() {
  box <- new.env(parent = emptyenv())
  list(box = box, remote = function(url, payload, timeout) {
    box$payload <- payload
    list(request_id = payload$request_id, status = "submitted", values = list(ok = TRUE))
  })
}
# Form files must live under the project's .claude directory (CLAUDE_PROJECT_DIR).
local_project <- function(env = parent.frame()) {
  project <- normalizePath(withr::local_tempdir(.local_envir = env))
  dir.create(file.path(project, ".claude", "forms"), recursive = TRUE)
  withr::local_envvar(CLAUDE_PROJECT_DIR = project, .local_envir = env)
  file.path(project, ".claude", "forms")
}
write_form <- function(x, dir = local_project(parent.frame()), name = "setup.json") {
  path <- file.path(dir, name)
  writeLines(if (is.character(x)) x else jsonlite::toJSON(x, auto_unbox = TRUE), path)
  path
}
form_def <- list(
  title = "Initial setup", submit_label = "Continue",
  fields = list(
    list(name = "study_id", label = "Study id", type = "text", section = "Study"),
    list(name = "dev_qc", label = "Role", type = "select", choices = list("dev", "qc"), default = "dev"),
    list(name = "domains", label = "Domains", type = "multiselect", choices = list("adsl", "adae", "adcm")),
    list(name = "adam_hub", label = "ADaM hub", type = "checkbox"),
    list(name = "cycle", label = "Cycle", type = "number")
  )
)

test_that("a form file supplies title, fields and submit label", {
  cap <- capture()
  env <- load_script(cap$remote)
  path <- write_form(form_def)
  res <- env$.ask_form_result(list(form_file = path))
  expect_null(res$isError)
  expect_identical(cap$box$payload$title, "Initial setup")
  expect_identical(cap$box$payload$submit_label, "Continue")
  expect_length(cap$box$payload$fields, 5L)
  expect_identical(cap$box$payload$fields[[1]]$section, "Study")
})

test_that("defaults fill fields by name, with typed values", {
  cap <- capture()
  env <- load_script(cap$remote)
  path <- write_form(form_def)
  env$.ask_form_result(list(form_file = path, title = "Setup bgb_x_101", defaults = list(
    study_id = "bgb_x_101", dev_qc = "qc", domains = list("adsl", "adae"), adam_hub = TRUE, cycle = 28
  )))
  fields <- setNames(cap$box$payload$fields, vapply(cap$box$payload$fields, `[[`, "", "name"))
  expect_identical(cap$box$payload$title, "Setup bgb_x_101")
  expect_identical(fields$study_id$default, "bgb_x_101")
  expect_identical(fields$dev_qc$default, "qc")
  expect_identical(fields$domains$default, "adsl,adae")
  expect_identical(fields$adam_hub$default, "true")
  expect_identical(fields$cycle$default, "28")
})

test_that("bad form files and defaults are reported to the model without asking", {
  cap <- capture()
  env <- load_script(cap$remote)
  dir <- local_project()
  err <- function(args) {
    cap$box$payload <- NULL
    res <- env$.ask_form_result(args)
    expect_true(isTRUE(res$isError), info = paste(names(args), collapse = ","))
    expect_null(cap$box$payload)
    res$content[[1]]$text
  }
  expect_match(err(list(form_file = "relative/setup.json")), "absolute", fixed = TRUE)
  expect_match(err(list(form_file = file.path(dir, "missing.json"))), "not found", fixed = TRUE)
  expect_match(err(list(form_file = write_form("x", dir, "setup.txt"))), ".json", fixed = TRUE)
  folder <- file.path(dir, "folder.json"); dir.create(folder)
  expect_match(err(list(form_file = folder)), "not found", fixed = TRUE)
  expect_match(err(list(form_file = write_form("{not json", dir, "bad.json"))), "valid JSON", fixed = TRUE)
  expect_match(err(list(form_file = write_form(list(title = "x"), dir, "nofields.json"))), "fields", fixed = TRUE)
  big <- write_form(paste0('{"title":"x","fields":[],"pad":"', strrep("p", 70000), '"}'), dir, "big.json")
  expect_match(err(list(form_file = big)), "64 KB", fixed = TRUE)
  ok <- write_form(form_def, dir, "ok.json")
  expect_match(err(list(form_file = ok, defaults = list(studyid = "x"))), "studyid", fixed = TRUE)
  expect_match(err(list(form_file = ok, fields = list(list(name = "a", type = "text")))), "either", fixed = TRUE)
  expect_match(err(list(title = "No fields")), "fields", fixed = TRUE)
})

test_that("defaults also work with inline fields", {
  cap <- capture()
  env <- load_script(cap$remote)
  env$.ask_form_result(list(title = "T", fields = list(list(name = "a", type = "text")),
                            defaults = list(a = "x")))
  expect_identical(cap$box$payload$fields[[1]]$default, "x")
})

test_that("the tool schema offers form_file and defaults and no longer requires fields", {
  env <- load_script(capture()$remote)
  schema <- env$ask_user_form$input_schema %||% env$ask_user_form$inputSchema
  expect_true(all(c("form_file", "defaults") %in% names(schema$properties)))
  expect_false("fields" %in% unlist(schema$required))
})

test_that("form files outside .claude, symlinks out of it and special files are refused", {
  cap <- capture()
  env <- load_script(cap$remote)
  forms <- local_project()
  outside <- withr::local_tempdir()
  stray <- file.path(outside, "setup.json")
  writeLines(jsonlite::toJSON(form_def, auto_unbox = TRUE), stray)
  res <- env$.ask_form_result(list(form_file = stray))
  expect_true(isTRUE(res$isError))
  expect_match(res$content[[1]]$text, ".claude directory", fixed = TRUE)
  link <- file.path(forms, "link.json")
  file.symlink(stray, link)
  expect_match(env$.ask_form_result(list(form_file = link))$content[[1]]$text, ".claude directory", fixed = TRUE)
  target <- file.path(forms, "notes.txt"); writeLines("{}", target)
  link2 <- file.path(forms, "alias.json"); file.symlink(target, link2)
  expect_match(env$.ask_form_result(list(form_file = link2))$content[[1]]$text, ".json file", fixed = TRUE)
  empty <- file.path(forms, "empty.json"); file.create(empty)
  expect_match(env$.ask_form_result(list(form_file = empty))$content[[1]]$text, "empty", fixed = TRUE)
  skip_if(Sys.which("mkfifo") == "")
  fifo <- file.path(forms, "pipe.json")
  system2("mkfifo", fifo)
  elapsed <- system.time(res <- env$.ask_form_result(list(form_file = fifo)))[["elapsed"]]
  expect_true(isTRUE(res$isError))
  expect_lt(elapsed, 2)
  expect_null(cap$box$payload)
})

test_that("field and default shapes are validated locally", {
  cap <- capture()
  env <- load_script(cap$remote)
  forms <- local_project()
  bad_fields <- write_form('{"title":"x","fields":[7]}', forms, "bad-fields.json")
  expect_match(env$.ask_form_result(list(form_file = bad_fields, defaults = list(a = 1)))$content[[1]]$text,
               "array of objects", fixed = TRUE)
  obj_fields <- write_form('{"title":"x","fields":{"name":"a","type":"text"}}', forms, "obj-fields.json")
  expect_match(env$.ask_form_result(list(form_file = obj_fields))$content[[1]]$text, "array of objects", fixed = TRUE)
  ok <- write_form(form_def, forms, "ok.json")
  expect_match(env$.ask_form_result(list(form_file = ok, defaults = list(study_id = list("x", "y"))))$content[[1]]$text,
               "single value", fixed = TRUE)
  expect_match(env$.ask_form_result(list(form_file = ok, defaults = list(domains = list(a = "x"))))$content[[1]]$text,
               "array of values", fixed = TRUE)
  expect_null(cap$box$payload)
  env$.ask_form_result(list(form_file = ok, defaults = list(dev_qc = NULL, cycle = 1e5)))
  fields <- setNames(cap$box$payload$fields, vapply(cap$box$payload$fields, `[[`, "", "name"))
  expect_identical(fields$dev_qc$default, "dev")
  expect_identical(fields$cycle$default, "100000")
})

test_that("a file swapped while being read is refused without blocking", {
  cap <- capture()
  env <- load_script(cap$remote)
  forms <- local_project()
  path <- write_form(form_def, forms, "race.json")
  outside <- file.path(withr::local_tempdir(), "outside.json")
  writeLines('{"title":"OUTSIDE","fields":[{"name":"a","type":"text"}]}', outside)
  original <- env$.read_bounded
  env$.read_bounded <- function(p, ...) {
    unlink(path); file.symlink(outside, path)   # swap after the checks
    original(p, ...)
  }
  res <- env$.ask_form_result(list(form_file = path))
  expect_true(isTRUE(res$isError))
  expect_match(res$content[[1]]$text, "changed while", fixed = TRUE)
  expect_null(cap$box$payload)

  skip_if(Sys.which("mkfifo") == "")
  path2 <- write_form(form_def, forms, "race2.json")
  env$.read_bounded <- function(p, ...) {
    unlink(path2); system2("mkfifo", path2)
    original(p, ...)
  }
  elapsed <- system.time(res <- env$.ask_form_result(list(form_file = path2)))[["elapsed"]]
  expect_true(isTRUE(res$isError))
  expect_lt(elapsed, 5)
  expect_null(cap$box$payload)
})

test_that("an empty defaults object is fine; an array is not", {
  cap <- capture()
  env <- load_script(cap$remote)
  path <- write_form(form_def)
  expect_null(env$.ask_form_result(list(form_file = path, defaults = jsonlite::fromJSON("{}", simplifyVector = FALSE)))$isError)
  res <- env$.ask_form_result(list(form_file = path, defaults = jsonlite::fromJSON("[]", simplifyVector = FALSE)))
  expect_true(isTRUE(res$isError))
  expect_match(res$content[[1]]$text, "object", fixed = TRUE)
})

test_that("without a bounded reader the file is refused instead of read in-process", {
  env <- load_script(capture()$remote)
  forms <- local_project()
  path <- write_form(form_def, forms, "nohead.json")
  expect_null(env$.read_bounded(path, head = ""))
  skip_if(Sys.which("mkfifo") == "")
  fifo <- file.path(forms, "nohead-pipe.json")
  system2("mkfifo", fifo)
  elapsed <- system.time(out <- env$.read_bounded(fifo, timeout = 0.5))[["elapsed"]]
  expect_null(out)
  expect_lt(elapsed, 3)
  expect_null(env$.read_bounded(fifo, head = ""))
})
