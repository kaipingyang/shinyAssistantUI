# Plan 166: AskUserForm rendered as a server-authoritative A2UI surface.

form_fields <- function() list(
  list(name = "dataset", label = "Dataset", type = "select",
       choices = list("iris", "mtcars"), default = "mtcars", required = TRUE),
  list(name = "n", label = "Rows", type = "number", default = "10"),
  list(name = "cols", label = "Columns", type = "multiselect",
       choices = list("mpg", "cyl", "hp"), default = "mpg,hp"),
  list(name = "note", label = "Note", type = "textarea", help = "Optional"),
  list(name = "plot", label = "Plot it", type = "checkbox", default = "true"),
  list(name = "since", label = "Since", type = "date", default = "2026-01-31"),
  list(name = "who", type = "text", required = TRUE)
)

form_request <- function(fields = form_fields(), request_id = "req-1", thread_id = "t1") {
  list(type = "ask_user_form", version = 1L, request_id = request_id, thread_id = thread_id,
       title = "Analysis settings", fields = fields, submit_label = "Run")
}

manual_timers <- function() {
  env <- new.env(parent = emptyenv())
  env$jobs <- list()
  list(
    schedule = function(callback, delay) {
      id <- length(env$jobs) + 1L
      env$jobs[[id]] <- list(callback = callback, delay = delay, active = TRUE)
      function() env$jobs[[id]]$active <- FALSE
    },
    fire = function() for (id in seq_along(env$jobs)) if (isTRUE(env$jobs[[id]]$active)) {
      env$jobs[[id]]$active <- FALSE
      env$jobs[[id]]$callback()
    },
    delays = function() vapply(env$jobs, `[[`, numeric(1), "delay")
  )
}

form_harness <- function(timeout = 600) {
  emitted <- new.env(parent = emptyenv())
  emitted$ops <- list()
  emitters <- shinyAssistantUI:::.new_ask_form_emitters()
  timers <- manual_timers()
  ids <- 0L
  service <- shinyAssistantUI:::.new_ask_form_service(
    emitters, timeout = timeout, schedule = timers$schedule,
    id_factory = function() { ids <<- ids + 1L; paste0("f", ids) }
  )
  emit <- function(operations, event_id = NULL, sequence = NULL) {
    emitted$ops[[length(emitted$ops) + 1L]] <- operations
    invisible(NULL)
  }
  responses <- new.env(parent = emptyenv())
  responses$all <- list()
  respond <- function(response) responses$all[[length(responses$all) + 1L]] <- response
  list(service = service, emitters = emitters, timers = timers, emit = emit,
       emitted = emitted, responses = responses, respond = respond)
}

test_that("form specs are validated and normalised like codeagent", {
  spec <- shinyAssistantUI:::.ask_form_validate_fields(form_fields())
  expect_true(is.list(spec))
  expect_identical(vapply(spec, `[[`, "", "type"),
                   c("select", "number", "multiselect", "textarea", "checkbox", "date", "text"))
  expect_identical(spec[[7]]$label, "who")          # label defaults to name
  expect_true(spec[[1]]$required)
  expect_identical(spec[[3]]$default, "mpg,hp")

  bad <- list(
    list(),
    list(list(name = "1x", type = "text")),
    list(list(name = "a", type = "slider")),
    list(list(name = "a", type = "select")),
    list(list(name = "a", type = "text"), list(name = "a", type = "number")),
    lapply(seq_len(21), function(i) list(name = paste0("f", i), type = "text"))
  )
  for (fields in bad) expect_type(shinyAssistantUI:::.ask_form_validate_fields(fields), "character")
})

test_that("the surface uses only supported A2UI components and binds every field", {
  spec <- shinyAssistantUI:::.ask_form_validate_fields(form_fields())
  ops <- shinyAssistantUI:::.ask_form_surface_ops("ask-form-f1", "Analysis settings", spec, "Run")
  expect_silent(shinyAssistantUI:::.a2ui_validate_operations(ops))
  components <- ops[[2]]$updateComponents$components
  by_id <- setNames(components, vapply(components, `[[`, "", "id"))
  expect_identical(by_id[["field-dataset"]]$component, "ChoicePicker")
  expect_identical(by_id[["field-cols"]]$variant, "multipleSelection")
  expect_identical(by_id[["field-note"]]$variant, "longText")
  expect_identical(by_id[["field-n"]]$variant, "number")
  expect_identical(by_id[["field-plot"]]$component, "CheckBox")
  expect_identical(by_id[["field-since"]]$component, "DateTimeInput")
  submit <- by_id[["submit"]]
  expect_identical(submit$action$event$name, "ask_form.submit")
  expect_identical(submit$action$event$context$formId, "ask-form-f1")
  expect_identical(names(submit$action$event$context$values),
                   c("dataset", "n", "cols", "note", "plot", "since", "who"))
  expect_identical(submit$action$event$context$values$cols$path, "/values/cols")
  expect_identical(by_id[["cancel"]]$action$event$name, "ask_form.cancel")
  model <- ops[[3]]$updateDataModel$value
  expect_identical(model$values$dataset, "mtcars")
  expect_identical(model$values$cols, list("mpg", "hp"))
  expect_identical(model$values$plot, TRUE)
  expect_identical(model$values$who, "")
  expect_identical(model$error, "")
})

test_that("submitted values are coerced, required fields and invalid values are reported", {
  spec <- shinyAssistantUI:::.ask_form_validate_fields(form_fields())
  ok <- shinyAssistantUI:::.ask_form_collect(spec, list(
    dataset = "iris", n = "25", cols = list("cyl"), note = "", plot = FALSE,
    since = "2026-02-01", who = "Ada"))
  expect_length(ok$problems, 0L)
  expect_identical(ok$values$n, 25)
  expect_identical(ok$values$cols, "cyl")
  expect_false(ok$values$plot)
  bad <- shinyAssistantUI:::.ask_form_collect(spec, list(
    dataset = "nope", n = "abc", cols = list("zzz"), plot = TRUE, since = "31/01/2026", who = ""))
  expect_match(paste(bad$problems, collapse = "\n"), "Dataset", fixed = TRUE)
  expect_match(paste(bad$problems, collapse = "\n"), "Rows", fixed = TRUE)
  expect_match(paste(bad$problems, collapse = "\n"), "Columns", fixed = TRUE)
  expect_match(paste(bad$problems, collapse = "\n"), "Since", fixed = TRUE)
  expect_match(paste(bad$problems, collapse = "\n"), "who", fixed = TRUE)
})

test_that("without an active conversation run the form is unavailable", {
  h <- form_harness()
  h$service$request(form_request(), h$respond)
  expect_identical(h$responses$all[[1]]$status, "unavailable")
  expect_identical(h$responses$all[[1]]$request_id, "req-1")
})

test_that("invalid specs and malformed requests return a fixable error", {
  h <- form_harness()
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(form_request(fields = list(list(name = "x", type = "select"))), h$respond)
  expect_identical(h$responses$all[[1]]$status, "invalid")
  expect_match(h$responses$all[[1]]$message, "choices")
  bad <- form_request(); bad$extra <- 1
  h$service$request(bad, h$respond)
  expect_identical(h$responses$all[[2]]$status, "invalid")
  expect_length(h$emitted$ops, 0L)
})

test_that("submit returns typed values once, after required fields are filled", {
  h <- form_harness()
  release <- h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(form_request(), h$respond)
  expect_length(h$emitted$ops, 1L)
  expect_length(h$responses$all, 0L)
  surface <- h$emitted$ops[[1]][[1]]$createSurface$surfaceId
  expect_identical(surface, "ask-form-f1")

  errors <- character()
  on_error <- function(reason) errors <<- c(errors, reason)
  values <- list(dataset = "iris", n = "5", cols = list("hp"), note = "x",
                 plot = TRUE, since = "2026-01-31", who = "")
  h$service$handle_action("ask_form.submit", list(formId = surface, values = values),
                          "t1", surface, on_error, h$emit, owner = "s1")
  expect_length(h$responses$all, 0L)
  error_update <- h$emitted$ops[[2]][[1]]$updateDataModel
  expect_identical(error_update$path, "/error")
  expect_match(error_update$value, "who")

  values$who <- "Ada"
  h$service$handle_action("ask_form.submit", list(formId = surface, values = values),
                          "t1", surface, on_error, h$emit, owner = "s1")
  expect_length(h$responses$all, 1L)
  response <- h$responses$all[[1]]
  expect_identical(response$status, "submitted")
  expect_identical(response$request_id, "req-1")
  expect_identical(response$values$n, 5)
  expect_identical(response$values$who, "Ada")
  # read-only summary replaces the inputs
  summary <- h$emitted$ops[[3]]
  root <- Filter(function(c) identical(c$id, "root"), summary[[1]]$updateComponents$components)[[1]]
  expect_false("submit" %in% unlist(root$children))
  expect_length(errors, 0L)

  # a second submit is stale
  h$service$handle_action("ask_form.submit", list(formId = surface, values = values),
                          "t1", surface, on_error, h$emit, owner = "s1")
  expect_length(h$responses$all, 1L)
  expect_length(errors, 1L)
  release()
})

test_that("cancel, Stop, timeout, session end and shutdown cancel pending forms", {
  h <- form_harness(timeout = 30)
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$emitters$register("t2", "run-2", h$emit, owner = "s2")
  start <- function(id, thread) h$service$request(form_request(request_id = id, thread_id = thread), h$respond)
  start("cancel", "t1")
  h$service$handle_action("ask_form.cancel", list(formId = "ask-form-f1"), "t1", "ask-form-f1",
                          function(reason) stop(reason), h$emit, owner = "s1")
  start("stop", "t1"); h$service$cancel_thread("t1", owner = "s1")
  start("owner", "t2"); h$service$cancel_owner("s2")
  start("timeout", "t1"); h$timers$fire()
  start("shutdown", "t1"); h$service$close()
  got <- setNames(vapply(h$responses$all, `[[`, "", "reason"),
                  vapply(h$responses$all, `[[`, "", "request_id"))
  expect_identical(unname(vapply(h$responses$all, `[[`, "", "status")), rep("cancelled", 5))
  expect_identical(got[["cancel"]], "user")
  expect_identical(got[["stop"]], "stopped")
  expect_identical(got[["owner"]], "disconnected")
  expect_identical(got[["timeout"]], "timeout")
  expect_identical(got[["shutdown"]], "shutdown")
})

test_that("actions for other threads or unknown forms are rejected", {
  h <- form_harness()
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(form_request(), h$respond)
  errors <- character()
  on_error <- function(reason) errors <<- c(errors, reason)
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list()),
                          "t2", "ask-form-f1", on_error, h$emit, owner = "s1")
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-zz", values = list()),
                          "t1", "ask-form-zz", on_error, h$emit, owner = "s1")
  h$service$handle_action("other.action", list(), "t1", "ask-form-f1", on_error, h$emit, owner = "s1")
  expect_length(errors, 3L)
  expect_length(h$responses$all, 0L)
})

test_that("emitter registrations are released only by their own token", {
  emitters <- shinyAssistantUI:::.new_ask_form_emitters()
  first <- emitters$register("t1", "run-1", function(...) "a", owner = "s1")
  second <- emitters$register("t1", "run-2", function(...) "b", owner = "s1")
  second()                                   # refused registration: no-op release
  expect_identical(emitters$get("t1")$run_id, "run-1")
  first()
  expect_null(emitters$get("t1"))
  third <- emitters$register("t1", "run-3", function(...) "c", owner = "s1")
  expect_identical(emitters$get("t1")$run_id, "run-3")
  first()                                    # stale release cannot remove the new run
  expect_identical(emitters$get("t1")$run_id, "run-3")
  third()
})

test_that("the form surface is accepted by the real A2UI authority", {
  sent <- list()
  session <- list(sendCustomMessage = function(type, message) sent[[length(sent) + 1L]] <<- list(type, message))
  transport <- shinyAssistantUI:::.new_a2ui_transport(session, "chat_input", "owner", NULL)
  spec <- shinyAssistantUI:::.ask_form_validate_fields(form_fields())
  ops <- shinyAssistantUI:::.ask_form_surface_ops("ask-form-f1", "Analysis settings", spec, "Run")
  expect_no_error(transport$send("t1", "run-1", ops, event_id = "ask-form-f1-create"))
  expect_true(transport$has_surface("t1", "ask-form-f1"))
})

test_that("addin-owned servers get thread ids and AskUserForm is auto-allowed", {
  servers <- list(
    ui = list(type = "stdio", command = "Rscript",
              env = list(CLAUDE_ADDIN_FORM_URL = "ipc:///tmp/f")),
    other = list(type = "stdio", command = "x", env = list(A = "1"))
  )
  out <- shinyAssistantUI:::.filter_run_r_mcp(servers, TRUE, thread_id = "thread-9")
  expect_identical(out$ui$env$CLAUDE_ADDIN_THREAD_ID, "thread-9")
  expect_null(out$other$env$CLAUDE_ADDIN_THREAD_ID)
  # the run_r toggle never removes the form server
  expect_false(is.null(shinyAssistantUI:::.filter_run_r_mcp(servers, FALSE)$ui))
})

test_that("the form MCP server config is curl-free stdio with a long tool timeout", {
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  cfg <- shinyAssistantUI:::.addin_ask_form_server("ipc:///tmp/form.sock")
  expect_identical(cfg$type, "stdio")
  expect_identical(cfg$env$CLAUDE_ADDIN_FORM_URL, "ipc:///tmp/form.sock")
  expect_gte(cfg$timeout, 600000)
  script <- cfg$args[[length(cfg$args)]]
  expect_true(file.exists(script))
  src <- paste(readLines(script), collapse = "\n")
  expect_false(grepl("library\\(ellmer|ellmer::", src))
})

load_form_script <- function(remote) {
  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI")
  if (!nzchar(script)) script <- "../../inst/mcp/ask_form_server.R"
  skip_if_not(file.exists(script))
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1",
                      CLAUDE_ADDIN_FORM_URL = "ipc:///tmp/form-test.sock",
                      CLAUDE_ADDIN_THREAD_ID = "thread-5",
                      .local_envir = parent.frame())
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  env$.form_remote <- remote
  env
}

test_that("AskUserForm MCP results match the codeagent contract", {
  seen <- NULL
  env <- load_form_script(function(url, payload, timeout) {
    seen <<- payload
    list(request_id = payload$request_id, status = "submitted",
         values = list(n = 5, who = "Ada"))
  })
  res <- env$.ask_form_result(list(title = "T", fields = list(list(name = "n", type = "number"))))
  expect_identical(seen$type, "ask_user_form")
  expect_identical(seen$thread_id, "thread-5")
  expect_identical(seen$title, "T")
  parsed <- jsonlite::fromJSON(res$content[[1]]$text)
  expect_true(parsed$submitted)
  expect_identical(parsed$values$who, "Ada")
  expect_null(res$isError)
})

test_that("cancelled, invalid, mismatched and missing replies are explicit", {
  reply <- NULL
  env <- load_form_script(function(url, payload, timeout) {
    if (is.list(reply)) reply$request_id <- reply$request_id %||% payload$request_id
    reply
  })
  reply <- list(status = "cancelled", reason = "user")
  cancelled <- jsonlite::fromJSON(env$.ask_form_result(list(title = "T", fields = list()))$content[[1]]$text)
  expect_false(cancelled$submitted)
  expect_identical(cancelled$reason, "user")

  reply <- list(status = "invalid", message = "Field 1: bad name")
  invalid <- env$.ask_form_result(list(title = "T", fields = list()))
  expect_true(isTRUE(invalid$isError))
  expect_match(invalid$content[[1]]$text, "bad name", fixed = TRUE)

  reply <- list(status = "submitted", values = list(a = 1), request_id = "someone-else")
  wrong <- jsonlite::fromJSON(env$.ask_form_result(list(title = "T", fields = list()))$content[[1]]$text)
  expect_false(wrong$submitted)

  reply <- NULL
  none <- jsonlite::fromJSON(env$.ask_form_result(list(title = "T", fields = list()))$content[[1]]$text)
  expect_false(none$submitted)
})

# ── review follow-ups ──────────────────────────────────────────────────────────
test_that("ending the registering run cancels its pending forms", {
  h <- form_harness()
  release <- h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(form_request(), h$respond)
  release()
  expect_identical(h$responses$all[[1]]$status, "cancelled")
  expect_identical(h$responses$all[[1]]$reason, "ended")
  errors <- character()
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list(who = "x")),
                          "t1", "ask-form-f1", function(r) errors <<- c(errors, r), h$emit, owner = "s1")
  expect_length(h$responses$all, 1L)
  expect_length(errors, 1L)
})

test_that("a second session cannot take over a thread's active registration", {
  h <- form_harness()
  first <- h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  second <- h$emitters$register("t1", "run-2", function(...) stop("wrong"), owner = "s2")
  expect_identical(h$emitters$get("t1")$owner, "s1")
  second()
  expect_identical(h$emitters$get("t1")$owner, "s1")
  first()
  expect_null(h$emitters$get("t1"))
})

test_that("only the owning session can answer or stop a form", {
  h <- form_harness()
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(form_request(fields = list(list(name = "x", type = "text"))), h$respond)
  errors <- character()
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list(x = "a")),
                          "t1", "ask-form-f1", function(r) errors <<- c(errors, r), h$emit, owner = "s2")
  h$service$cancel_thread("t1", owner = "s2")
  expect_length(h$responses$all, 0L)
  expect_length(errors, 1L)
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list(x = "a")),
                          "t1", "ask-form-f1", function(r) errors <<- c(errors, r), h$emit, owner = "s1")
  expect_identical(h$responses$all[[1]]$status, "submitted")
})

test_that("the form tool is auto-allowed only by explicit addin opt-in", {
  expect_identical(shinyAssistantUI:::.addin_form_allowed_tools(NULL), "mcp__ui__AskUserForm")
  expect_identical(shinyAssistantUI:::.addin_form_allowed_tools(c("Read", "mcp__ui__AskUserForm")),
                   c("Read", "mcp__ui__AskUserForm"))
  # make_claude_handler never infers it from a configured `ui` server
  src <- paste(deparse(body(shinyAssistantUI::make_claude_handler)), collapse = "\n")
  expect_false(grepl("addin_form_allowed_tools", src, fixed = TRUE))
  cfg <- if (requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
             "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK")) {
    shinyAssistantUI:::.addin_ask_form_server("ipc:///tmp/f")
  } else NULL
  if (!is.null(cfg)) expect_false(any(grepl("TOKEN", names(cfg$env))))
})

test_that("at most 12 forms per thread may be open at once", {
  h <- form_harness()
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  for (i in seq_len(12)) {
    h$service$request(form_request(fields = list(list(name = "x", type = "text")),
                                   request_id = paste0("r", i)), h$respond)
  }
  expect_length(h$responses$all, 0L)
  h$service$request(form_request(request_id = "r13"), h$respond)
  expect_identical(h$responses$all[[1]]$status, "unavailable")
  expect_match(h$responses$all[[1]]$message, "open")
})

test_that("oversized requests, choices and answers are rejected before the authority", {
  big <- form_request(fields = list(list(name = "x", type = "select",
                                         choices = list(strrep("c", 201), "b"))))
  h <- form_harness()
  h$emitters$register("t1", "run-1", h$emit, owner = "s1")
  h$service$request(big, h$respond)
  expect_identical(h$responses$all[[1]]$status, "invalid")
  huge <- form_request(fields = lapply(1:20, function(i) list(name = paste0("f", i), type = "text",
                                                           help = strrep("h", 500), default = strrep("d", 4000))))
  h$service$request(huge, h$respond)
  expect_identical(h$responses$all[[2]]$status, "invalid")
  spec <- shinyAssistantUI:::.ask_form_validate_fields(list(list(name = "t", type = "textarea")))
  long <- shinyAssistantUI:::.ask_form_collect(spec, list(t = strrep("x", 4001)))
  expect_match(long$problems, "too long")
})

test_that("the read-only summary is shown before Claude receives the values", {
  order <- character()
  h <- form_harness()
  emit <- function(operations, ...) {
    if (!is.null(operations[[1]]$updateComponents)) order <<- c(order, "summary")
    invisible(NULL)
  }
  h$emitters$register("t1", "run-1", emit, owner = "s1")
  h$service$request(form_request(fields = list(list(name = "x", type = "text"))),
                    function(r) order <<- c(order, paste0("respond:", r$status)))
  h$service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list(x = "a")),
                          "t1", "ask-form-f1", function(r) NULL, emit, owner = "s1")
  expect_identical(order, c("summary", "respond:submitted"))
})
