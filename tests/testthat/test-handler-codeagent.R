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
