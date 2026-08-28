test_that("large character tool results are spooled behind bounded metadata", {
  root <- tempfile("lazy-tool-results-")
  store <- .new_lazy_tool_result_store(root = root, threshold_bytes = 16, chunk_bytes = 7)
  on.exit(store$cleanup(), add = TRUE)

  text <- paste0("start-", strrep("界", 12), "-end")
  descriptor <- store$put(text, thread_id = "thread-a", tool_call_id = "tool-a")

  expect_identical(descriptor$kind, "lazy-tool-result")
  expect_identical(descriptor$version, 1L)
  expect_equal(descriptor$originalBytes, nchar(enc2utf8(text), type = "bytes"))
  expect_identical(descriptor$chunkBytes, 7L)
  expect_false(any(vapply(descriptor, identical, logical(1), text)))

  snapshot <- store$snapshot()
  expect_length(snapshot, 1L)
  entry <- snapshot[[descriptor$handle]]
  expect_true(file.exists(entry$path))
  expect_identical(entry[c("thread_id", "tool_call_id", "generation")], list(
    thread_id = "thread-a", tool_call_id = "tool-a", generation = descriptor$generation
  ))
  expect_false("result" %in% names(entry))
  expect_false("text" %in% names(entry))
  expect_equal(unclass(bitwAnd(file.info(entry$path)$mode, as.octmode("077"))), 0L)
})

test_that("lazy chunks are UTF-8 safe, sequential, ownership checked, and bounded", {
  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 1, chunk_bytes = 7
  )
  on.exit(store$cleanup(), add = TRUE)
  text <- paste0("A", strrep("界🙂", 6), "Z")
  descriptor <- store$put(text, thread_id = "thread-a", tool_call_id = "tool-a")

  offset <- 0L
  chunks <- character()
  repeat {
    chunk <- store$read_chunk(
      handle = descriptor$handle,
      generation = descriptor$generation,
      thread_id = "thread-a",
      tool_call_id = "tool-a",
      offset = offset,
      max_bytes = 7
    )
    expect_type(chunk$text, "character")
    expect_false(is.na(iconv(chunk$text, from = "UTF-8", to = "UTF-8")))
    expect_lte(nchar(chunk$text, type = "bytes"), 7)
    chunks <- c(chunks, chunk$text)
    offset <- chunk$nextOffset
    if (isTRUE(chunk$done)) break
  }
  expect_identical(paste0(chunks, collapse = ""), enc2utf8(text))
  expect_identical(offset, descriptor$originalBytes)

  expect_null(store$read_chunk(
    descriptor$handle, descriptor$generation, "thread-b", "tool-a", 0L, 7L
  ))
  expect_null(store$read_chunk(
    descriptor$handle, descriptor$generation + 1L, "thread-a", "tool-a", 0L, 7L
  ))
  expect_null(store$read_chunk(
    descriptor$handle, descriptor$generation, "thread-a", "tool-a", -1L, 7L
  ))
})

test_that("small and structured results stay on the existing immediate path", {
  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 32, chunk_bytes = 8
  )
  on.exit(store$cleanup(), add = TRUE)

  expect_null(store$put("small", "thread", "tool"))
  expect_null(store$put(list(value = strrep("x", 100)), "thread", "structured"))
  expect_length(store$snapshot(), 0L)
})

test_that("cleanup removes every private lazy result artifact", {
  root <- tempfile("lazy-tool-results-")
  store <- .new_lazy_tool_result_store(root = root, threshold_bytes = 1, chunk_bytes = 8)
  descriptor <- store$put(strrep("x", 100), "thread", "tool")
  path <- store$snapshot()[[descriptor$handle]]$path
  expect_true(dir.exists(root))
  expect_true(file.exists(path))

  store$cleanup()
  expect_false(dir.exists(root))
  expect_length(store$snapshot(), 0L)
  expect_null(store$read_chunk(
    descriptor$handle, descriptor$generation, "thread", "tool", 0L, 8L
  ))
})


test_that("refreshing the same thread tool replaces its old artifact", {
  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 1, chunk_bytes = 8
  )
  on.exit(store$cleanup(), add = TRUE)
  first <- store$put(strrep("a", 20), "thread", "tool")
  first_path <- store$snapshot()[[first$handle]]$path
  second <- store$put(strrep("b", 20), "thread", "tool")

  expect_false(file.exists(first_path))
  expect_length(store$snapshot(), 1L)
  expect_true(second$generation > first$generation)
})


test_that("assistantUIServer sends metadata first and serves character chunks on demand", {
  old_threshold <- getOption("shinyAssistantUI.lazy_tool_result_threshold_bytes")
  old_chunk <- getOption("shinyAssistantUI.lazy_tool_result_chunk_bytes")
  old_max <- getOption("shinyAssistantUI.claude_tool_result_max_bytes")
  options(
    shinyAssistantUI.lazy_tool_result_threshold_bytes = 32,
    shinyAssistantUI.lazy_tool_result_chunk_bytes = 16,
    shinyAssistantUI.claude_tool_result_max_bytes = 80
  )
  on.exit(options(
    shinyAssistantUI.lazy_tool_result_threshold_bytes = old_threshold,
    shinyAssistantUI.lazy_tool_result_chunk_bytes = old_chunk,
    shinyAssistantUI.claude_tool_result_max_bytes = old_max
  ), add = TRUE)

  full <- paste0("BEGIN-", strrep("界", 30), "-END")
  sent <- list()
  handler <- function(message, on_tool_call, on_tool_result, on_done, ...) {
    on_tool_call("tool-lazy", "Bash", list(command = "synthetic"))
    on_tool_result("tool-lazy", full)
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "run", threadId = "thread-lazy", runId = "run-lazy", ts = 1
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now(timeoutSecs = 0.01)
      session$flushReact()
    }

    result_messages <- Filter(function(x) identical(x$type, "chat_input:tool-result"), sent)
    expect_length(result_messages, 1L)
    descriptor <- result_messages[[1L]]$message$result
    expect_identical(descriptor$kind, "lazy-tool-result")
    expect_identical(descriptor$threadId, "thread-lazy")
    expect_identical(descriptor$toolCallId, "tool-lazy")
    expect_lte(descriptor$originalBytes, 80)
    expect_equal(descriptor$sourceBytes, nchar(enc2utf8(full), type = "bytes"))
    expect_true(isTRUE(descriptor$truncated))
    expect_match(descriptor$summary, "Bounded.*preview")
    expect_false(any(vapply(descriptor, identical, logical(1), full)))

    sent <<- list()
    session$setInputs(chat_input_tool_result_chunk = list(
      handle = descriptor$handle,
      generation = descriptor$generation,
      threadId = descriptor$threadId,
      toolCallId = descriptor$toolCallId,
      requestId = "request-1",
      offset = 0,
      maxBytes = descriptor$chunkBytes,
      ts = 2
    ))
    session$flushReact()

    chunks <- Filter(function(x) identical(x$type, "chat_input:tool-result-chunk"), sent)
    expect_length(chunks, 1L)
    chunk <- chunks[[1L]]$message
    expect_identical(chunk$requestId, "request-1")
    expect_lte(nchar(chunk$text, type = "bytes"), descriptor$chunkBytes)
    expect_true(chunk$nextOffset > 0)
    expect_false(isTRUE(chunk$done))
  })
})

test_that("non-progressive rich result types retain the immediate payload contract", {
  old_threshold <- getOption("shinyAssistantUI.lazy_tool_result_threshold_bytes")
  options(shinyAssistantUI.lazy_tool_result_threshold_bytes = 8)
  on.exit(options(shinyAssistantUI.lazy_tool_result_threshold_bytes = old_threshold), add = TRUE)

  html <- paste0("<p>", strrep("content", 20), "</p>")
  sent <- list()
  handler <- function(message, on_tool_call, on_tool_result, on_done, ...) {
    on_tool_call(
      "tool-html", "Custom", list(),
      annotations = list(resultType = "html")
    )
    on_tool_result("tool-html", html)
    on_done()
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      text = "run", threadId = "thread-html", runId = "run-html", ts = 1
    ))
    session$flushReact()
    for (i in seq_len(20L)) {
      later::run_now(timeoutSecs = 0.01)
      session$flushReact()
    }
  })

  result_messages <- Filter(function(x) identical(x$type, "chat_input:tool-result"), sent)
  expect_length(result_messages, 1L)
  expect_identical(result_messages[[1L]]$message$result, html)
})


test_that("history load spools large collapsed tool results before the Shiny payload", {
  old_threshold <- getOption("shinyAssistantUI.lazy_tool_result_threshold_bytes")
  old_chunk <- getOption("shinyAssistantUI.lazy_tool_result_chunk_bytes")
  options(
    shinyAssistantUI.lazy_tool_result_threshold_bytes = 32,
    shinyAssistantUI.lazy_tool_result_chunk_bytes = 16
  )
  on.exit(options(
    shinyAssistantUI.lazy_tool_result_threshold_bytes = old_threshold,
    shinyAssistantUI.lazy_tool_result_chunk_bytes = old_chunk
  ), add = TRUE)

  full <- paste0("HISTORY-", strrep("界", 30))
  sent <- list()
  loader <- function(session_id, thread_id, send_thread, ...) {
    send_thread(list(list(
      id = "history-assistant",
      role = "assistant",
      status = list(type = "complete", reason = "stop"),
      content = list(list(
        type = "tool-call",
        toolCallId = "history-tool",
        toolName = "Bash",
        args = list(command = "synthetic"),
        argsText = "{\"command\":\"synthetic\"}",
        result = full,
        isError = FALSE,
        artifact = list(defaultOpen = FALSE)
      ))
    )))
  }

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = function(...) NULL, on_session_load = loader)
  }, {
    session$sendCustomMessage <- function(type, message) {
      sent[[length(sent) + 1L]] <<- list(type = type, message = message)
    }
    session$flushReact()
    session$setInputs(chat_input = list(
      type = "load_session",
      sessionId = "session-history",
      threadId = "thread-history",
      requestId = "history-request",
      ts = 1
    ))
    session$flushReact()
  })

  loads <- Filter(function(x) identical(x$type, "chat_input:load-thread"), sent)
  expect_length(loads, 1L)
  part <- loads[[1L]]$message$messages[[1L]]$content[[1L]]
  expect_identical(part$result$kind, "lazy-tool-result")
  expect_identical(part$result$threadId, "thread-history")
  expect_identical(part$result$toolCallId, "history-tool")
  expect_identical(part$artifact$inputId, "chat_input")
  expect_false(any(vapply(part$result, identical, logical(1), full)))
})


test_that("identical owner content reuses its descriptor while changed content rotates", {
  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 1, chunk_bytes = 8
  )
  on.exit(store$cleanup(), add = TRUE)
  text <- strrep("same-content\n", 8)
  first <- store$put(text, "thread", "tool", source_bytes = 999)
  second <- store$put(text, "thread", "tool", source_bytes = 999)

  expect_identical(second$handle, first$handle)
  expect_identical(second$generation, first$generation)
  expect_identical(second$sourceBytes, 999)
  expect_true(isTRUE(second$truncated))
  expect_length(store$snapshot(), 1L)
  expect_identical(
    store$read_chunk(first$handle, first$generation, "thread", "tool", 0, 8)$text,
    substr(text, 1, 8)
  )

  third <- store$put(strrep("changed\n", 8), "thread", "tool", source_bytes = 999)
  expect_gt(third$generation, first$generation)
  expect_null(store$read_chunk(first$handle, first$generation, "thread", "tool", 0, 8))
})

test_that("lazy store enforces session file and byte ceilings with LRU eviction", {
  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 1, chunk_bytes = 8,
    max_entries = 2, max_total_bytes = 48
  )
  on.exit(store$cleanup(), add = TRUE)
  first <- store$put(strrep("a", 20), "thread", "one")
  second <- store$put(strrep("b", 20), "thread", "two")
  third <- store$put(strrep("c", 20), "thread", "three")

  expect_length(store$snapshot(), 2L)
  expect_null(store$read_chunk(first$handle, first$generation, "thread", "one", 0, 8))
  expect_false(is.null(store$read_chunk(second$handle, second$generation, "thread", "two", 0, 8)))
  expect_false(is.null(store$read_chunk(third$handle, third$generation, "thread", "three", 0, 8)))
  expect_null(store$put(strrep("z", 60), "thread", "too-large"))
  expect_lte(sum(vapply(store$snapshot(), `[[`, numeric(1), "bytes")), 48)
})


test_that("UI and session resource options cannot raise hard safety ceilings", {
  old_max <- getOption("shinyAssistantUI.claude_tool_result_max_bytes")
  options(shinyAssistantUI.claude_tool_result_max_bytes = 2 * 1024^2)
  on.exit(options(shinyAssistantUI.claude_tool_result_max_bytes = old_max), add = TRUE)
  expect_equal(.claude_ui_tool_result_max_bytes(), 1024^2)

  store <- .new_lazy_tool_result_store(
    root = tempfile("lazy-tool-results-"), threshold_bytes = 1,
    max_entries = 256, max_total_bytes = 256 * 1024^2
  )
  on.exit(store$cleanup(), add = TRUE)
  expect_identical(store$limits(), list(
    max_entries = 128L,
    max_total_bytes = 128 * 1024^2
  ))
})
