history_fixture_entry <- function(type, uuid, parent = NULL, content = NULL, ...) {
  entry <- list(
    type = type,
    uuid = uuid,
    parentUuid = parent,
    sessionId = "11111111-1111-4111-8111-111111111111",
    message = list(content = content)
  )
  modifyList(entry, list(...))
}

write_history_jsonl <- function(path, entries, trailing_lf = TRUE) {
  text <- paste(vapply(entries, function(entry) {
    as.character(jsonlite::toJSON(entry, auto_unbox = TRUE, null = "null"))
  }, character(1)), collapse = "\n")
  if (trailing_lf) text <- paste0(text, "\n")
  con <- file(path, open = "wb")
  on.exit(close(con), add = TRUE)
  writeBin(charToRaw(text), con)
}

history_fixture <- function() {
  list(
    history_fixture_entry("user", "u1", content = "question one"),
    history_fixture_entry("assistant", "a1", "u1", list(list(
      type = "tool_use", id = "tool-1", name = "Read",
      input = list(file_path = "R/example.R")
    ))),
    history_fixture_entry("user", "r1", "a1", list(list(
      type = "tool_result", tool_use_id = "tool-1", content = "tool result one",
      is_error = FALSE
    ))),
    history_fixture_entry("assistant", "a2", "r1", list(list(
      type = "text", text = "answer one"
    ))),
    history_fixture_entry("user", "u2", "a2", content = "question two"),
    history_fixture_entry("assistant", "a3", "u2", list(list(
      type = "text", text = "answer two"
    )))
  )
}


test_that("Claude history index ignores an incomplete trailing JSONL record", {
  path <- tempfile(fileext = ".jsonl")
  write_history_jsonl(path, history_fixture()[1:2])
  cat('{"type":"assistant","uuid":"partial"', file = path, append = TRUE)

  index <- .build_claude_history_index(path, sdk_version = "0.2.5")

  expect_identical(vapply(index$entries, `[[`, character(1), "uuid"), c("u1", "a1"))
  expect_lt(index$source$complete_end, file.info(path)$size)
})


test_that("Claude history sidecar is mode 0600 and rebuilds after corruption", {
  path <- tempfile(fileext = ".jsonl")
  root <- tempfile("history-index-")
  dir.create(root)
  write_history_jsonl(path, history_fixture())

  first <- .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  expect_true(file.exists(first$sidecar_path))
  expect_identical(as.character(as.octmode(file.info(first$sidecar_path)$mode)), "600")
  writeBin(charToRaw("not an rds"), first$sidecar_path)

  rebuilt <- .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  expect_length(rebuilt$entries, length(history_fixture()))
  expect_identical(rebuilt$revision, first$revision)
  expect_silent(readRDS(rebuilt$sidecar_path))
})


test_that("Claude history sidecar directory enforces entry and byte budgets", {
  root <- tempfile("bounded-history-index-")
  source_root <- tempfile("history-sources-")
  sources <- file.path(source_root, paste0("session-", 1:5, ".jsonl"))
  dir.create(source_root, recursive = TRUE)
  on.exit(unlink(c(root, source_root), recursive = TRUE, force = TRUE), add = TRUE)
  for (path in sources) write_history_jsonl(path, history_fixture())

  withr::local_options(list(
    shinyAssistantUI.history_index_entries = 2L,
    shinyAssistantUI.history_index_bytes = 1024^3
  ))
  loaded <- lapply(sources[1:4], function(path) {
    .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  })
  sidecars <- list.files(root, pattern = "^history-.*[.]rds$", full.names = TRUE)
  expect_lte(length(sidecars), 2L)
  expect_true(file.exists(loaded[[4L]]$sidecar_path))

  byte_root <- tempfile("byte-bounded-history-index-")
  on.exit(unlink(byte_root, recursive = TRUE, force = TRUE), add = TRUE)
  withr::local_options(list(
    shinyAssistantUI.history_index_entries = 10L,
    shinyAssistantUI.history_index_bytes = 1024^3
  ))
  first <- .load_claude_history_index(
    sources[[1L]], cache_root = byte_root, sdk_version = "0.2.5"
  )
  byte_limit <- as.numeric(file.info(first$sidecar_path)$size) * 2 + 128
  options(shinyAssistantUI.history_index_bytes = byte_limit)
  for (path in sources[2:5]) {

    .load_claude_history_index(path, cache_root = byte_root, sdk_version = "0.2.5")
  }
  byte_sidecars <- list.files(
    byte_root, pattern = "^history-.*[.]rds$", full.names = TRUE
  )
  expect_lte(sum(file.info(byte_sidecars)$size), byte_limit)
})


test_that("history source identity detects same-size same-mtime rewrites", {
  path <- tempfile(fileext = ".jsonl")
  root <- tempfile("rewrite-history-index-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  write_history_jsonl(path, history_fixture())
  original_mtime <- file.info(path)$mtime

  first <- .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  bytes <- readBin(path, what = "raw", n = file.info(path)$size)
  text <- rawToChar(bytes)
  rewritten <- sub("question one", "question zne", text, fixed = TRUE)
  expect_identical(nchar(rewritten, type = "bytes"), nchar(text, type = "bytes"))
  writeBin(charToRaw(rewritten), path)
  Sys.setFileTime(path, original_mtime)

  second <- .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  expect_false(identical(second$revision, first$revision))
  expect_false(identical(second$source$sample_hash, first$source$sample_hash))
})


test_that("one oversized history sidecar cannot exceed the hard byte budget", {
  path <- tempfile(fileext = ".jsonl")
  root <- tempfile("oversized-history-index-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  entries <- unlist(replicate(80L, history_fixture(), simplify = FALSE), recursive = FALSE)
  entries <- Map(function(entry, index) {
    entry$uuid <- paste0(entry$uuid, "-", index)
    entry
  }, entries, seq_along(entries))
  write_history_jsonl(path, entries)
  withr::local_options(list(
    shinyAssistantUI.history_index_entries = 10L,
    shinyAssistantUI.history_index_bytes = 1024
  ))

  .load_claude_history_index(path, cache_root = root, sdk_version = "0.2.5")
  sidecars <- list.files(root, pattern = "^history-.*[.]rds$", full.names = TRUE)
  expect_lte(sum(file.info(sidecars)$size), 1024)
})


test_that("indexed Claude pages keep complete turns and tool results", {
  path <- tempfile(fileext = ".jsonl")
  write_history_jsonl(path, history_fixture())
  index <- .build_claude_history_index(path, sdk_version = "0.2.5")


  newest <- .claude_index_page(index, limit = 2L, traversal_id = "traversal-1")
  expect_identical(
    vapply(newest$messages, `[[`, character(1), "id"),
    c("h-u2", "h-a3")
  )
  expect_true(newest$has_more)
  expect_true(is.character(newest$cursor) && nzchar(newest$cursor))

  older <- .claude_index_page(
    index, cursor = newest$cursor, limit = 2L, traversal_id = "traversal-1"
  )
  expect_identical(
    vapply(older$messages, `[[`, character(1), "id"),
    c("h-u1", "h-a1", "h-a2")
  )
  tool <- older$messages[[2L]]$content[[1L]]
  expect_identical(tool$type, "tool-call")
  expect_identical(tool$result, "tool result one")
  expect_false(older$has_more)
})


test_that("opaque history cursors are revision and traversal bound", {
  path <- tempfile(fileext = ".jsonl")
  write_history_jsonl(path, history_fixture())
  first_index <- .build_claude_history_index(path, sdk_version = "0.2.5")
  first <- .claude_index_page(first_index, limit = 2L, traversal_id = "traversal-a")

  expect_true(.claude_index_page(
    first_index, cursor = first$cursor, limit = 2L, traversal_id = "traversal-b"
  )$stale)

  cat(as.character(jsonlite::toJSON(history_fixture_entry(
    "user", "u3", "a3", "question three"
  ), auto_unbox = TRUE, null = "null")), "\n", file = path, append = TRUE, sep = "")
  second_index <- .build_claude_history_index(path, sdk_version = "0.2.5")
  expect_false(identical(second_index$revision, first_index$revision))
  expect_true(.claude_index_page(
    second_index, cursor = first$cursor, limit = 2L, traversal_id = "traversal-a"
  )$stale)
})


test_that("history page cache enforces byte LRU and explicit release", {
  cache <- .new_history_page_cache(max_entries = 3L, max_bytes = 12000)
  expect_true(cache$set("a", raw(5000)))
  expect_true(cache$set("b", raw(5000)))
  expect_length(cache$get("a"), 5000L)
  expect_true(cache$set("c", raw(5000)))

  expect_true(cache$has("a"))
  expect_false(cache$has("b"))
  expect_true(cache$has("c"))
  expect_lte(cache$stats()$bytes, 12000)
  expect_true(cache$release("a"))
  expect_false(cache$has("a"))
})


test_that("Claude fallback full-parses at most once per traversal", {
  path <- tempfile(fileext = ".rds")
  reads <- 0L
  raw <- lapply(seq_len(8L), function(index) list(
    type = if (index %% 2L) "user" else "assistant",
    uuid = paste0("fallback-", index),
    message = list(content = if (index %% 2L) paste0("q", index) else list(list(
      type = "text", text = paste0("a", index)
    )))
  ))
  local_mocked_bindings(
    .claude_history_index_capability = function() list(ok = FALSE, reason = "unsupported"),
    .get_claude_session_messages = function(...) {
      reads <<- reads + 1L
      raw
    }
  )
  loader <- make_claude_session_loader(path)
  pages <- list()
  capture <- function(messages, cursor = NULL, has_more = FALSE, ...) {
    pages[[length(pages) + 1L]] <<- list(
      messages = messages, cursor = cursor, has_more = has_more
    )
  }

  loader("fallback-session", "fallback-thread", capture, limit = 2L)
  expect_identical(reads, 1L)
  loader(
    "fallback-session", "fallback-thread", capture,
    cursor = pages[[1L]]$cursor, limit = 2L
  )
  expect_identical(reads, 1L)
  expect_true(length(pages[[1L]]$messages) <= 2L)
  expect_true(length(pages[[2L]]$messages) <= 2L)
})


test_that("indexed turn paging does not include an extra complete turn past the soft limit", {
  entries <- history_fixture()
  entries <- c(entries, list(
    history_fixture_entry("user", "u3", "a3", content = "question three"),
    history_fixture_entry("assistant", "a4", "u3", list(list(
      type = "text", text = "answer three"
    )))
  ))
  path <- tempfile(fileext = ".jsonl")
  write_history_jsonl(path, entries)
  index <- .build_claude_history_index(path, sdk_version = "0.2.5")

  newest <- .claude_index_page(index, limit = 3L, traversal_id = "soft-limit")
  expect_identical(
    vapply(newest$messages, `[[`, character(1), "id"),
    c("h-u3", "h-a4")
  )
  older <- .claude_index_page(
    index, cursor = newest$cursor, limit = 3L, traversal_id = "soft-limit"
  )
  expect_identical(
    vapply(older$messages, `[[`, character(1), "id"),
    c("h-u2", "h-a3")
  )
})


test_that("Claude loader uses the supported index without public full parsing", {
  path <- tempfile(fileext = ".jsonl")
  root <- tempfile("loader-index-")
  dir.create(root)
  write_history_jsonl(path, history_fixture())
  public_reads <- 0L
  withr::local_options(shinyAssistantUI.history_index_dir = root)
  local_mocked_bindings(
    .claude_history_index_capability = function() list(
      ok = TRUE,
      version = "0.2.5",
      finder = function(session_id, directory) path
    ),
    .get_claude_session_messages = function(...) {
      public_reads <<- public_reads + 1L
      stop("public parser must not run")
    }
  )
  loader <- make_claude_session_loader(tempfile(fileext = ".rds"))
  pages <- list()
  capture <- function(messages, cursor = NULL, has_more = FALSE, ...) {
    pages[[length(pages) + 1L]] <<- list(
      messages = messages, cursor = cursor, has_more = has_more
    )
  }

  loader("indexed-session", "indexed-thread", capture, limit = 2L)
  loader(
    "indexed-session", "indexed-thread", capture,
    cursor = pages[[1L]]$cursor, limit = 2L
  )

  expect_identical(public_reads, 0L)
  expect_length(pages, 2L)
  expect_false(pages[[2L]]$has_more)
  expect_true(length(list.files(root, pattern = "[.]rds$")) >= 1L)
})
