# Plan 51 A — make_codeagent_handler adapter: callback forwarding + display split + on_done.
# Deterministic (injected fake stream_fn; duck-typed client; no codeagent/LLM needed).

test_that(".codeagent_display_to_ui routes image / code / table / plain by kind", {
  f <- shinyAssistantUI:::.codeagent_display_to_ui
  cap <- new.env()
  on_image  <- function(uri) cap$img <- uri
  on_art    <- function(id, title, content, type, lang = NULL) cap$art <- list(type = type, content = content, lang = lang, title = title)
  on_tr     <- function(tool_call_id, result, is_error) cap$tr <- list(result = result, is_error = is_error)

  # image → data URI from payload$images[[1]]$b64/mime
  f(list(id = "1", value = "v", display = list(toolcard = list(kind = "image",
        payload = list(images = list(list(mime = "image/png", b64 = "AAA")))))), on_image, on_art, on_tr)
  expect_equal(cap$img, "data:image/png;base64,AAA")

  # code → on_artifact(type=code, lang, content=payload$text)
  f(list(id = "2", value = "v", display = list(toolcard = list(kind = "code",
        payload = list(text = "lm(y ~ x)", lang = "r")))), on_image, on_art, on_tr)
  expect_equal(cap$art$type, "code"); expect_equal(cap$art$content, "lm(y ~ x)"); expect_equal(cap$art$lang, "r")

  # diff → on_artifact(type=code, lang=diff)
  f(list(id = "3", value = "d", display = list(toolcard = list(kind = "diff", payload = list(text = "- a\n+ b")))), on_image, on_art, on_tr)
  expect_equal(cap$art$lang, "diff")

  # table → on_artifact(type=markdown, content=display$markdown)
  f(list(id = "4", value = "v", display = list(markdown = "| a |\n|---|\n| 1 |", toolcard = list(kind = "table"))), on_image, on_art, on_tr)
  expect_equal(cap$art$type, "markdown"); expect_true(grepl("\\| a \\|", cap$art$content))

  # plain text → on_tool_result
  f(list(id = "5", value = "hi", is_error = FALSE, display = list(toolcard = list(kind = "text"))), on_image, on_art, on_tr)
  expect_equal(cap$tr$result, "hi"); expect_false(cap$tr$is_error)
})

test_that("make_codeagent_handler forwards stream callbacks and calls on_done", {
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  # Fake stream_fn: fires callbacks synchronously, then resolves the turn promise.
  fake_stream <- function(client, input, on_delta = NULL, on_thinking = NULL,
                          on_tool_request = NULL, on_tool_result = NULL,
                          on_error = NULL, controller = NULL, session_id = NULL, ...) {
    if (is.function(on_delta)) { on_delta("Hello "); on_delta("world") }
    if (is.function(on_tool_request))
      on_tool_request(list(id = "t1", name = "run_r", arguments = list(code = "1+1"), intent = "compute"))
    if (is.function(on_tool_result))
      on_tool_result(list(id = "t1", name = "run_r", value = "2", is_error = FALSE,
                          display = list(toolcard = list(kind = "code", payload = list(text = "1+1", lang = "r")))))
    promises::promise_resolve(list(text = "Hello world", usage = NULL, stop_reason = "completed"))
  }

  h <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),
    stream_fn = fake_stream
  )

  cap <- new.env(); cap$chunks <- character(0); cap$done <- FALSE
  h(message = "hi", thread_id = "th1", attachments = list(),
    on_chunk       = function(t) cap$chunks <- c(cap$chunks, t),
    on_done        = function(...) cap$done <- TRUE,
    on_error       = function(m) cap$err <- m,
    on_tool_call   = function(tool_call_id, tool_name, args, annotations) cap$toolcall <- tool_name,
    on_tool_result = function(tool_call_id, result, is_error) cap$tr <- result,
    on_thinking    = NULL,
    on_image       = function(u) cap$img <- u,
    on_artifact    = function(id, title, content, type, lang = NULL) cap$art <- list(type = type, content = content),
    is_cancelled   = function() FALSE,
    wait_for_approval = NULL,
    register_cancel   = function(fn) NULL)

  # h is coro::async → pump the later loop until on_done (or timeout).
  for (i in seq_len(2000)) { later::run_now(); if (cap$done) break; Sys.sleep(0.002) }

  expect_true(cap$done)
  expect_identical(paste(cap$chunks, collapse = ""), "Hello world")
  expect_identical(cap$toolcall, "run_r")           # on_tool_request → on_tool_call
  expect_identical(cap$art$type, "code")            # code display → on_artifact
  expect_identical(cap$art$content, "1+1")
})


# Plan 51 B — permission bridge: the gate's ask_fn -> approval card -> approve/deny.
# Injected fake gate_fn captures the ask_fn; a fake stream_fn invokes it mid-turn
# exactly as codeagent's real gate would. No codeagent / LLM needed.

test_that("permission bridge: ask_fn emits requiresApproval card and resolves approve/deny", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")

  captured <- new.env()
  fake_gate <- function(chat, permission_mode, ask_fn, rules = list()) {
    captured$ask_fn <- ask_fn; captured$mode <- permission_mode; captured$rules <- rules
  }

  run_bridge <- function(approve) {
    cap <- new.env(); cap$done <- FALSE; cap$ask_result <- NULL
    fake_stream <- function(client, input, on_delta = NULL, on_tool_request = NULL, ...) {
      p <- captured$ask_fn("run_r", list(code = "1+1"), id = "t1")   # gate asks
      promises::then(p, function(ok) cap$ask_result <- ok)
      promises::promise_resolve(list(text = "done", usage = NULL, stop_reason = "completed"))
    }
    h <- make_codeagent_handler(
      client_factory  = function() structure(list(chat = list()), class = "CodeagentClient"),
      permission_mode = "default", stream_fn = fake_stream, gate_fn = fake_gate)
    h(message = "hi", thread_id = "th", attachments = list(),
      on_chunk = function(t) NULL, on_done = function(...) cap$done <- TRUE,
      on_error = function(m) cap$err <- m,
      on_tool_call = function(tool_call_id, tool_name, args, annotations) {
        cap$tc_id <- tool_call_id; cap$tc_ann <- annotations
      },
      on_tool_result = function(...) NULL, on_thinking = NULL,
      on_image = function(...) NULL, on_artifact = function(...) NULL,
      is_cancelled = function() FALSE,
      wait_for_approval = function(id) promises::promise_resolve(list(approved = approve)),
      register_cancel = function(fn) NULL)
    for (i in seq_len(3000)) { later::run_now(); if (isTRUE(cap$done) && !is.null(cap$ask_result)) break; Sys.sleep(0.002) }
    cap
  }

  ap <- run_bridge(TRUE)
  expect_true(isTRUE(ap$tc_ann$requiresApproval))   # approval card emitted for the tool
  expect_identical(ap$tc_id, "t1")                  # same id the gate passed
  expect_identical(captured$mode, "default")        # our permission_mode installed on the gate
  expect_true(isTRUE(ap$ask_result))                # approve -> ask_fn promise resolves TRUE

  dn <- run_bridge(FALSE)
  expect_false(isTRUE(dn$ask_result))               # deny -> FALSE
})

test_that("permission bridge: no approval channel denies (safe default)", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")

  captured <- new.env()
  fake_gate <- function(chat, permission_mode, ask_fn, rules = list()) captured$ask_fn <- ask_fn
  cap <- new.env(); cap$done <- FALSE
  fake_stream <- function(client, input, ...) {
    cap$ask_result <- captured$ask_fn("Bash", list(command = "echo hi"), id = "x")  # no wait_for_approval wired
    promises::promise_resolve(list(text = "done"))
  }
  h <- make_codeagent_handler(
    client_factory = function() structure(list(chat = list()), class = "CodeagentClient"),
    stream_fn = fake_stream, gate_fn = fake_gate)
  h(message = "hi", thread_id = "th", attachments = list(),
    on_chunk = function(t) NULL, on_done = function(...) cap$done <- TRUE, on_error = function(m) NULL,
    on_tool_call = function(...) NULL, on_tool_result = function(...) NULL, on_thinking = NULL,
    on_image = function(...) NULL, on_artifact = function(...) NULL,
    is_cancelled = function() FALSE, wait_for_approval = NULL, register_cancel = function(fn) NULL)
  for (i in seq_len(2000)) { later::run_now(); if (isTRUE(cap$done)) break; Sys.sleep(0.002) }
  expect_false(isTRUE(cap$ask_result))              # logical FALSE (deny), not a promise
})

test_that("gate is skipped when client exposes no $chat (Phase A / duck-typed clients unaffected)", {
  called <- new.env(); called$n <- 0L
  fake_gate <- function(...) called$n <- called$n + 1L
  h <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),  # no $chat
    stream_fn = function(...) promises::promise_resolve(list(text = "x")),
    gate_fn = fake_gate)
  # build the client (warmup path also uses get_client)
  attr(h, "warmup")("th")
  expect_identical(called$n, 0L)                    # gate_fn not called when $chat is NULL
})


test_that("approval_tools maps to codeagent PermissionRule-shaped ask rules (not list(ask=))", {
  captured <- new.env()
  fake_gate <- function(chat, permission_mode, ask_fn, rules = list()) captured$rules <- rules
  h <- make_codeagent_handler(
    client_factory = function() structure(list(chat = list()), class = "CodeagentClient"),
    approval_tools = c("Glob", "RunR"),
    stream_fn = function(...) promises::promise_resolve(list(text = "x")),
    gate_fn = fake_gate)
  attr(h, "warmup")("th")                      # triggers get_client -> gate_fn(rules=)
  expect_length(captured$rules, 2)
  expect_identical(captured$rules[[1]]$tool_name, "Glob")
  expect_identical(captured$rules[[1]]$behavior, "ask")
  expect_true("rule_content" %in% names(captured$rules[[1]]))

  # the shape is actually honored by codeagent's own gate: a read-only tool that
  # would auto-allow in "default" mode is forced to "ask" by this rule.
  skip_if_not_installed("codeagent")
  cp <- getFromNamespace("check_permission", "codeagent")
  expect_identical(cp("Glob", "default", rules = list()), "allow")        # baseline
  expect_identical(cp("Glob", "default", rules = captured$rules), "ask")  # forced
})


# Plan 65 — latest codeagent: Data Shield boundary, usage, multimodal input,
# terminal state, and lifecycle. All tests use injected fakes (no LLM/network).

.make_p65_shield <- function(scan_fn, close_fn = function() NULL,
                              scan_prompt_fn = function(text, ...) list(action = "pass", text = text)) {
  structure(
    list(
      scan_response = scan_fn,
      scan_prompt = scan_prompt_fn,
      close = close_fn,
      coverage = function() list(datasets = "protected_demo")
    ),
    class = "DataShield"
  )
}

.run_p65_handler <- function(handler, cap, attachments = list(), message = "hello") {
  handler(
    message = message, thread_id = "plan65-thread", attachments = attachments,
    on_chunk = function(text) cap$chunks <- c(cap$chunks, text),
    on_done = function(...) cap$done <- cap$done + 1L,
    on_error = function(message) cap$errors <- c(cap$errors, message),
    on_tool_call = function(tool_call_id, tool_name, args, annotations) {
      cap$tool_calls[[length(cap$tool_calls) + 1L]] <- list(
        id = tool_call_id, name = tool_name, args = args, annotations = annotations
      )
    },
    on_tool_result = function(tool_call_id, result, is_error) {
      cap$tool_results[[length(cap$tool_results) + 1L]] <- list(
        id = tool_call_id, result = result, is_error = is_error
      )
    },
    on_thinking = function(text) cap$thinking <- c(cap$thinking, text),
    on_image = function(uri) cap$images <- c(cap$images, uri),
    on_artifact = function(...) cap$artifacts <- cap$artifacts + 1L,
    on_usage = function(...) cap$usage[[length(cap$usage) + 1L]] <- list(...),
    on_status = function(status, text = NULL) {
      cap$status[[length(cap$status) + 1L]] <- list(status = status, text = text)
    },
    is_cancelled = function() isTRUE(cap$cancelled),
    wait_for_approval = cap$wait_for_approval,
    register_cancel = function(fn) cap$cancel <- fn
  )
}

.new_p65_capture <- function() {
  cap <- new.env(parent = emptyenv())
  cap$chunks <- character(); cap$thinking <- character(); cap$errors <- character()
  cap$tool_calls <- list(); cap$tool_results <- list(); cap$images <- character()
  cap$artifacts <- 0L; cap$usage <- list(); cap$status <- list(); cap$done <- 0L
  cap$cancelled <- FALSE; cap$wait_for_approval <- NULL; cap$cancel <- NULL
  cap
}

.pump_p65 <- function(predicate, limit = 3000L) {
  for (i in seq_len(limit)) {
    later::run_now()
    if (isTRUE(predicate())) return(invisible(TRUE))
    Sys.sleep(0.001)
  }
  invisible(FALSE)
}

test_that("Data Shield holds all text and projects tool channels before release", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")

  secret <- "PLAN65_PRIVATE_9X"
  pending <- new.env(parent = emptyenv())
  shield <- .make_p65_shield(function(text, ...) {
    if (identical(text, paste0("answer ", secret))) {
      return(list(action = "redact", text = "answer [PROTECTED]"))
    }
    list(action = "pass", text = text)
  })
  client <- structure(
    list(chat = list(), settings = list(model = "demo", model_limit = 1000L), data_shield = shield),
    class = "CodeagentClient"
  )
  fake_stream <- function(client, input, on_delta = NULL, on_thinking = NULL,
                          on_tool_request = NULL, on_tool_result = NULL,
                          on_error = NULL, on_usage = NULL, ...) {
    on_delta("answer PLAN65_")
    on_delta("PRIVATE_9X")
    on_thinking(paste("reasoning about", secret))
    on_tool_request(list(
      id = "tool-1", name = "RunR",
      arguments = list(code = paste("print", secret)), intent = paste("inspect", secret)
    ))
    on_tool_result(list(
      id = "tool-1", name = "RunR", value = "[PROTECTED]", is_error = FALSE,
      display = list(
        markdown = paste("table", secret),
        toolcard = list(kind = "code", payload = list(text = secret, lang = "r"))
      )
    ))
    on_usage(list(n_tokens = 123L, model_limit = 1000L, cost_last = 0.02))
    promises::promise(function(resolve, reject) pending$resolve <- resolve)
  }
  h <- make_codeagent_handler(
    client_factory = function() client, stream_fn = fake_stream,
    gate_fn = function(...) NULL
  )
  cap <- .new_p65_capture()
  .run_p65_handler(h, cap)
  expect_true(.pump_p65(function() is.function(pending$resolve)))

  # Nothing model-generated reaches the browser before the whole response scan.
  expect_length(cap$chunks, 0L)
  expect_length(cap$thinking, 0L)
  expect_length(cap$tool_calls, 1L)
  expect_identical(cap$tool_calls[[1L]]$args, list())
  expect_false("intent" %in% names(cap$tool_calls[[1L]]$annotations))
  expect_length(cap$tool_results, 1L)
  expect_identical(cap$tool_results[[1L]]$result, "[PROTECTED]")
  expect_identical(cap$artifacts, 0L)
  expect_length(cap$images, 0L)

  # Usage is context occupancy, not a fabricated cumulative token total.
  expect_length(cap$usage, 1L)
  expect_identical(cap$usage[[1L]]$context_tokens, 123L)
  expect_identical(cap$usage[[1L]]$context_window, 1000L)
  expect_identical(cap$usage[[1L]]$cost_usd, 0.02)
  expect_null(cap$usage[[1L]]$tokens)

  pending$resolve(list(text = paste0("answer ", secret), stop_reason = "completed"))
  expect_true(.pump_p65(function() cap$done == 1L))
  expect_identical(cap$chunks, "answer [PROTECTED]")
  browser_payload <- paste(c(
    cap$chunks,
    unlist(lapply(cap$tool_calls, function(x) jsonlite::toJSON(x, auto_unbox = TRUE))),
    unlist(lapply(cap$tool_results, function(x) jsonlite::toJSON(x, auto_unbox = TRUE)))
  ), collapse = "\n")
  expect_false(grepl(secret, browser_payload, fixed = TRUE))
})

test_that("Data Shield output scan fails closed for block, error, and malformed returns", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  secret <- "PLAN65_NEVER_BROWSER"
  cases <- list(
    block = function(text, ...) list(action = "block", text = paste("blocked", secret)),
    error = function(text, ...) stop(paste("scanner leaked", secret)),
    malformed = function(text, ...) list(action = "pass")
  )

  for (scan_fn in cases) {
    cap <- .new_p65_capture()
    client <- structure(
      list(chat = list(), settings = list(), data_shield = .make_p65_shield(scan_fn)),
      class = "CodeagentClient"
    )
    h <- make_codeagent_handler(
      client_factory = function() client,
      stream_fn = function(client, input, on_delta = NULL, ...) {
        on_delta(secret)
        promises::promise_resolve(list(text = secret, stop_reason = "completed"))
      },
      gate_fn = function(...) NULL
    )
    .run_p65_handler(h, cap)
    expect_true(.pump_p65(function() cap$done == 1L))
    expect_length(cap$chunks, 1L)
    expect_false(grepl(secret, paste(c(cap$chunks, cap$errors), collapse = "\n"), fixed = TRUE))
    expect_match(cap$chunks[[1L]], "Data Shield", fixed = TRUE)
  }
})

test_that("Data Shield approval cards never expose raw tool input", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  secret <- "PLAN65_APPROVAL_SECRET"
  gate <- new.env(parent = emptyenv())
  client <- structure(
    list(
      chat = list(), settings = list(),
      data_shield = .make_p65_shield(function(text, ...) list(action = "pass", text = text))
    ),
    class = "CodeagentClient"
  )
  h <- make_codeagent_handler(
    client_factory = function() client,
    gate_fn = function(chat, permission_mode, ask_fn, rules = list()) gate$ask <- ask_fn,
    stream_fn = function(...) {
      gate$decision <- gate$ask("Bash", list(command = paste("echo", secret)), id = "approval-1")
      promises::promise_resolve(list(text = "safe", stop_reason = "completed"))
    }
  )
  cap <- .new_p65_capture()
  cap$wait_for_approval <- function(id) promises::promise_resolve(list(approved = FALSE))
  .run_p65_handler(h, cap)
  expect_true(.pump_p65(function() cap$done == 1L))
  expect_length(cap$tool_calls, 1L)
  expect_identical(cap$tool_calls[[1L]]$args, list())
  expect_false(grepl(secret, jsonlite::toJSON(cap$tool_calls, auto_unbox = TRUE), fixed = TRUE))
})

test_that("non-Shield codeagent receives ordered ContentImage inputs including image-only", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  skip_if_not_installed("ellmer")
  captured <- list()
  fake_stream <- function(client, input, ...) {
    captured[[length(captured) + 1L]] <<- input
    promises::promise_resolve(list(text = "ok", stop_reason = "completed"))
  }
  h <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),
    stream_fn = fake_stream, gate_fn = function(...) NULL
  )
  image_atts <- list(
    list(type = "image", data = "data:image/png;base64,AAA", name = "a.png"),
    list(type = "image", data = "data:image/jpeg;base64,BBB", name = "b.jpg")
  )
  cap1 <- .new_p65_capture(); .run_p65_handler(h, cap1, image_atts)
  expect_true(.pump_p65(function() cap1$done == 1L))
  expect_type(captured[[1L]], "list")
  expect_identical(captured[[1L]][[1L]], "hello")
  expect_true(S7::S7_inherits(captured[[1L]][[2L]], ellmer::ContentImage))
  expect_true(S7::S7_inherits(captured[[1L]][[3L]], ellmer::ContentImage))

  cap2 <- .new_p65_capture()
  h(message = "", thread_id = "image-only", attachments = image_atts,
    on_chunk = function(text) cap2$chunks <- c(cap2$chunks, text),
    on_done = function(...) cap2$done <- cap2$done + 1L,
    on_error = function(message) cap2$errors <- c(cap2$errors, message),
    on_tool_call = function(...) NULL, on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL, on_image = function(...) NULL,
    on_artifact = function(...) NULL, on_usage = function(...) NULL,
    on_status = function(...) NULL, is_cancelled = function() FALSE,
    wait_for_approval = NULL, register_cancel = function(fn) NULL)
  expect_true(.pump_p65(function() cap2$done == 1L))
  expect_identical(captured[[2L]][[1L]], "")
  expect_length(captured[[2L]], 3L)
})

test_that("Shield rejects image input before invoking codeagent stream", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  calls <- 0L
  client <- structure(
    list(
      chat = list(), settings = list(),
      data_shield = .make_p65_shield(function(text, ...) list(action = "pass", text = text))
    ),
    class = "CodeagentClient"
  )
  h <- make_codeagent_handler(
    client_factory = function() client,
    stream_fn = function(...) { calls <<- calls + 1L; promises::promise_resolve(list()) },
    gate_fn = function(...) NULL
  )
  cap <- .new_p65_capture()
  .run_p65_handler(h, cap, list(list(
    type = "image", data = "data:image/png;base64,PRIVATE_IMAGE_BYTES", name = "private.png"
  )))
  expect_true(.pump_p65(function() cap$done == 1L))
  expect_identical(calls, 0L)
  expect_match(cap$chunks[[1L]], "Data Shield", fixed = TRUE)
  expect_false(grepl("PRIVATE_IMAGE_BYTES", paste(cap$chunks, collapse = ""), fixed = TRUE))
})

test_that("non-Shield rich image display forwards every image in order", {
  images <- character()
  shinyAssistantUI:::.codeagent_display_to_ui(
    list(
      id = "multi-image", value = "ok", is_error = FALSE,
      display = list(toolcard = list(
        kind = "image",
        payload = list(images = list(
          list(mime = "image/png", b64 = "AAA"),
          list(mime = "image/jpeg", b64 = "BBB")
        ))
      ))
    ),
    on_image = function(uri) images <<- c(images, uri),
    on_artifact = function(...) NULL,
    on_tool_result = function(...) NULL
  )
  expect_identical(images, c(
    "data:image/png;base64,AAA",
    "data:image/jpeg;base64,BBB"
  ))
})

test_that("codeagent error and cancellation do not also emit normal done", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")

  cap_error <- .new_p65_capture()
  h_error <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),
    stream_fn = function(client, input, on_error = NULL, ...) {
      on_error("backend failed", FALSE)
      promises::promise_resolve(list(text = "", stop_reason = "error"))
    }, gate_fn = function(...) NULL
  )
  .run_p65_handler(h_error, cap_error)
  expect_true(.pump_p65(function() length(cap_error$errors) == 1L))
  later::run_now(); expect_identical(cap_error$done, 0L)

  cap_cancel <- .new_p65_capture(); cap_cancel$cancelled <- TRUE
  h_cancel <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),
    stream_fn = function(...) promises::promise_resolve(list(text = "partial", stop_reason = "completed")),
    gate_fn = function(...) NULL
  )
  .run_p65_handler(h_cancel, cap_cancel)
  for (i in seq_len(20)) later::run_now()
  expect_identical(cap_cancel$done, 0L)
})

test_that("codeagent handler validates current permission modes and tears down shields once", {
  expect_no_error(make_codeagent_handler(
    function() structure(list(), class = "CodeagentClient"),
    permission_mode = "bypass", stream_fn = function(...) promises::promise_resolve(list())
  ))
  expect_error(
    make_codeagent_handler(
      function() structure(list(), class = "CodeagentClient"),
      permission_mode = "bypassPermissions",
      stream_fn = function(...) promises::promise_resolve(list())
    ),
    "bypass"
  )

  closed <- 0L
  shield <- .make_p65_shield(
    function(text, ...) list(action = "pass", text = text),
    close_fn = function() closed <<- closed + 1L
  )
  client <- structure(list(data_shield = shield), class = "CodeagentClient")
  h <- make_codeagent_handler(
    client_factory = function() client,
    stream_fn = function(...) promises::promise_resolve(list()),
    gate_fn = function(...) NULL
  )
  attr(h, "warmup")("teardown-thread")
  expect_true(is.function(attr(h, "teardown")))
  attr(h, "teardown")()
  attr(h, "teardown")()
  expect_identical(closed, 1L)
})


test_that("Data Shield input scan fails closed before stream invocation", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  secret <- "PLAN65_INPUT_SCAN_SECRET"
  cases <- list(
    error = function(text, ...) stop("scanner unavailable"),
    malformed = function(text, ...) list(action = "pass"),
    block = function(text, ...) list(action = "block", text = secret)
  )
  for (prompt_scan in cases) {
    calls <- 0L
    shield <- .make_p65_shield(
      function(text, ...) list(action = "pass", text = text),
      scan_prompt_fn = prompt_scan
    )
    client <- structure(list(chat = list(), settings = list(), data_shield = shield),
                        class = "CodeagentClient")
    h <- make_codeagent_handler(
      client_factory = function() client,
      stream_fn = function(...) {
        calls <<- calls + 1L
        promises::promise_resolve(list(text = "unsafe", stop_reason = "completed"))
      },
      gate_fn = function(...) NULL
    )
    cap <- .new_p65_capture()
    .run_p65_handler(h, cap, message = secret)
    expect_true(.pump_p65(function() cap$done == 1L))
    expect_identical(calls, 0L)
    expect_false(grepl(secret, paste(cap$chunks, collapse = "\n"), fixed = TRUE))
    expect_match(cap$chunks[[1L]], "Data Shield", fixed = TRUE)
  }
})

test_that("Data Shield scans tool values and replaces provider-controlled IDs", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  secret <- "PLAN65_TOOL_BROWSER_SECRET"
  shield <- .make_p65_shield(function(text, ...) {
    list(action = "redact", text = gsub(secret, "[PROTECTED]", text, fixed = TRUE))
  })
  client <- structure(list(chat = list(), settings = list(), data_shield = shield),
                      class = "CodeagentClient")
  h <- make_codeagent_handler(
    client_factory = function() client,
    stream_fn = function(client, input, on_tool_request = NULL, on_tool_result = NULL, ...) {
      on_tool_request(list(id = paste0("id-", secret), name = "RunR",
                           arguments = list(code = secret), intent = secret))
      on_tool_result(list(id = paste0("id-", secret), name = "RunR", value = secret,
                          is_error = FALSE,
                          display = list(toolcard = list(kind = "image", payload = list(
                            images = list(list(src = secret)))))))
      promises::promise_resolve(list(text = "safe final", stop_reason = "completed"))
    }, gate_fn = function(...) NULL
  )
  cap <- .new_p65_capture()
  .run_p65_handler(h, cap)
  expect_true(.pump_p65(function() cap$done == 1L))
  payload <- jsonlite::toJSON(list(calls = cap$tool_calls, results = cap$tool_results),
                              auto_unbox = TRUE)
  expect_false(grepl(secret, payload, fixed = TRUE))
  expect_identical(cap$tool_calls[[1L]]$id, cap$tool_results[[1L]]$id)
  expect_match(cap$tool_calls[[1L]]$id, "^shield-tool-[0-9]+$")
  expect_identical(cap$tool_results[[1L]]$result, "[PROTECTED]")
  expect_identical(cap$artifacts, 0L)
  expect_length(cap$images, 0L)
})

test_that("cancelled codeagent ignores upstream on_error and emits no terminal callback", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  cap <- .new_p65_capture(); cap$cancelled <- TRUE
  h <- make_codeagent_handler(
    client_factory = function() structure(list(), class = "CodeagentClient"),
    stream_fn = function(client, input, on_error = NULL, ...) {
      on_error("User interrupted", FALSE)
      promises::promise_resolve(list(text = "", stop_reason = "error"))
    }, gate_fn = function(...) NULL
  )
  .run_p65_handler(h, cap)
  for (i in seq_len(30)) later::run_now()
  expect_length(cap$errors, 0L)
  expect_identical(cap$done, 0L)
})

test_that("store receives non-Shield chat only and is skipped under Shield", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  saved <- list()
  store <- list(save = function(id, chat, title, first_msg) {
    saved[[length(saved) + 1L]] <<- list(id = id, chat = chat, title = title, first_msg = first_msg)
  })
  chat <- list(marker = "ellmer-chat")
  plain <- structure(list(chat = chat), class = "CodeagentClient")
  h_plain <- make_codeagent_handler(
    client_factory = function() plain, store = store,
    stream_fn = function(...) promises::promise_resolve(list(text = "ok", stop_reason = "completed")),
    gate_fn = function(...) NULL
  )
  cap_plain <- .new_p65_capture(); .run_p65_handler(h_plain, cap_plain)
  expect_true(.pump_p65(function() cap_plain$done == 1L))
  expect_length(saved, 1L)
  expect_identical(saved[[1L]]$chat, chat)

  shield <- .make_p65_shield(function(text, ...) list(action = "pass", text = text))
  protected <- structure(list(chat = list(marker = "protected"), settings = list(), data_shield = shield),
                         class = "CodeagentClient")
  h_shield <- make_codeagent_handler(
    client_factory = function() protected, store = store,
    stream_fn = function(...) promises::promise_resolve(list(text = "safe", stop_reason = "completed")),
    gate_fn = function(...) NULL
  )
  cap_shield <- .new_p65_capture(); .run_p65_handler(h_shield, cap_shield)
  expect_true(.pump_p65(function() cap_shield$done == 1L))
  expect_length(saved, 1L)
})


test_that("Shield tool IDs remain stable within a turn and unique across turns", {
  skip_if_not_installed("coro"); skip_if_not_installed("promises"); skip_if_not_installed("later")
  shield <- .make_p65_shield(function(text, ...) list(action = "pass", text = text))
  client <- structure(list(chat = list(), settings = list(), data_shield = shield),
                      class = "CodeagentClient")
  h <- make_codeagent_handler(
    client_factory = function() client,
    stream_fn = function(client, input, on_tool_request = NULL, on_tool_result = NULL, ...) {
      on_tool_request(list(id = "provider-reused-id", name = "RunR", arguments = list()))
      on_tool_result(list(id = "provider-reused-id", name = "RunR", value = "safe",
                          is_error = FALSE))
      promises::promise_resolve(list(text = "safe", stop_reason = "completed"))
    }, gate_fn = function(...) NULL
  )
  first <- .new_p65_capture(); .run_p65_handler(h, first)
  expect_true(.pump_p65(function() first$done == 1L))
  second <- .new_p65_capture(); .run_p65_handler(h, second)
  expect_true(.pump_p65(function() second$done == 1L))

  expect_identical(first$tool_calls[[1L]]$id, first$tool_results[[1L]]$id)
  expect_identical(second$tool_calls[[1L]]$id, second$tool_results[[1L]]$id)
  expect_false(identical(first$tool_calls[[1L]]$id, second$tool_calls[[1L]]$id))
})
