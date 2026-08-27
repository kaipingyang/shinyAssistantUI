test_that("context formatter keeps only summary + category and drops detail sections", {
  usage <- list(
    model = "claude_*[x]<tag>|",
    total_tokens = 12345,
    maxTokens = 200000,
    raw_max_tokens = 210000,
    percentage = 6.2,
    is_auto_compact_enabled = TRUE,
    autoCompactThreshold = 80,
    categories = list(system = 1200, "tool*use" = list(tokens = 34)),
    memory_files = list(list(path = "notes_[x].md", tokens = 12)),
    mcpTools = list(list(name = "db|read", server = "srv<1>")),
    agents = c("Explore", "Plan"),
    system_tools = list("Read", "Edit"),
    systemPromptSections = list(list(name = "policy#1", tokens = 99)),
    slash_commands = list(list(name = "/review", description = "check *all*")),
    skills = list("r_pkg" = list(tokens = 7)),
    messageBreakdown = list(user = 20, assistant = 30),
    api_usage = list(inputTokens = 44, cache = list(read = 5)),
    deferredBuiltinTools = list("WebSearch", list(name = "Task", state = "later")),
    extra_data = list("odd*key" = list("<raw>" = "a|b")),
    ignored_null = NULL,
    ignored_empty = list()
  )

  text <- .format_context_usage(usage)

  # 摘要 + 分类表保留
  expect_match(text, "# Context Usage", fixed = TRUE)
  expect_match(text, "claude_*[x]&lt;tag&gt;\\|", fixed = TRUE)
  expect_match(text, "12.3k / 210k", fixed = TRUE)
  expect_match(text, "Effective limit", fixed = TRUE)
  expect_match(text, "Auto-compact", fixed = TRUE)
  expect_match(text, "## Estimated usage by category", fixed = TRUE)

  # 明细段全部砍掉
  for (heading in c(
    "Memory Files", "MCP Tools", "Custom Agents", "System Tools",
    "System Prompt Sections", "Slash Commands", "Skills",
    "Message Breakdown", "API Usage", "Deferred Builtin Tools",
    "Context Grid", "Additional Fields"
  )) {
    expect_false(grepl(paste0("## ", heading), text, fixed = TRUE),
                 info = paste("detail section should be dropped:", heading))
  }
})

test_that("context formatter accepts NULL, snake case and false without detail sections", {
  expect_identical(.format_context_usage(NULL), "Context usage is unavailable.")

  text <- .format_context_usage(list(
    total_tokens = 0,
    is_auto_compact_enabled = FALSE,
    mystery = list(list(a = 1), list(b = list(c = "x_y")))
  ))

  expect_match(text, "**Tokens:** 0", fixed = TRUE)
  expect_match(text, "**Auto-compact:** disabled", fixed = TRUE)
  # 未知字段不再作为 Additional Fields 渲染
  expect_false(grepl("Additional Fields", text, fixed = TRUE))
})

test_that("context action returns the trimmed formatter output offline", {
  skip_if_not_installed("ClaudeAgentSDK")

  usage <- list(
    model = "mock-model",
    totalTokens = 10,
    maxTokens = 100,
    categories = list(system = 3),
    messageBreakdown = list(user = 2),
    deferredBuiltinTools = list("WebSearch")
  )
  context_pending <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$get_context_usage <- function() stop("synchronous context reader must not be used")
  client$get_context_usage_async <- function(timeout_ms = 5000L,
                                             on_fulfilled = NULL, on_rejected = NULL) {
    context_pending <<- list(
      timeout_ms = timeout_ms, resolve = on_fulfilled, reject = on_rejected
    )
    invisible("context-request")
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client
  )

  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  attr(handler, "warmup")("thread-context")
  result <- NULL
  attr(handler, "action_handler")(
    "context", "thread-context",
    function(message, status = "ok", value = NULL) {
      result <<- list(message = message, status = status, value = value)
    }
  )

  expect_null(result)
  expect_identical(context_pending$timeout_ms, 5000L)
  expect_true(is.function(context_pending$resolve))
  context_pending$resolve(usage)

  expect_identical(result$status, "ok")
  expect_match(result$message, "# Context Usage", fixed = TRUE)
  expect_match(result$message, "## Estimated usage by category", fixed = TRUE)
  expect_false(grepl("## Message Breakdown", result$message, fixed = TRUE))
  expect_false(grepl("## Deferred Builtin Tools", result$message, fixed = TRUE))
})


test_that("context formatter renders summary + category table, no detail tables", {
  usage <- list(
    model = "claude-sonnet-4.6",
    totalTokens = 151500,
    maxTokens = 967000,
    rawMaxTokens = 1000000,
    percentage = 15.15,
    isAutoCompactEnabled = TRUE,
    autoCompactThreshold = 967000,
    categories = list(
      list(name = "System prompt", tokens = 6700),
      list(name = "System tools", tokens = 17200),
      list(name = "Messages", tokens = 219300),
      list(name = "Free space", tokens = 704500),
      list(name = "Autocompact buffer", tokens = 33000)
    ),
    agents = list(
      list(agentType = "code-reviewer", source = "User", tokens = 38)
    ),
    memoryFiles = list(
      list(type = "Project", path = "/project/CLAUDE.md", tokens = 9800)
    ),
    skills = list(
      list(name = "tdd-workflow", source = "User", tokens = 46)
    )
  )

  text <- .format_context_usage(usage)

  expect_match(text, "# Context Usage", fixed = TRUE)
  expect_match(text, "**Model:** `claude-sonnet-4.6`", fixed = TRUE)
  expect_match(text, "**Tokens:** 151.5k / 1m (15.2%)", fixed = TRUE)
  expect_match(text, "## Estimated usage by category", fixed = TRUE)
  expect_match(text, "| Category | Tokens | Percentage |", fixed = TRUE)
  expect_match(text, "| System prompt | 6.7k | 0.7% |", fixed = TRUE)
  # 明细表不再出现
  expect_false(grepl("## Custom Agents", text, fixed = TRUE))
  expect_false(grepl("## Memory Files", text, fixed = TRUE))
  expect_false(grepl("## Skills", text, fixed = TRUE))
})


test_that("Result usage is immediate and legacy sync context usage is never automatic", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  queue <- list(structure(list(
    subtype = "success",
    duration_ms = 25,
    duration_api_ms = 20,
    is_error = FALSE,
    num_turns = 2L,
    session_id = "session-result-usage",
    result = "Finished.",
    total_cost_usd = 0.012,
    usage = list(
      input_tokens = 100L,
      cache_read_input_tokens = 20L,
      cache_creation_input_tokens = 5L,
      output_tokens = 10L
    ),
    model = list("claude-test" = list()),
    stop_reason = "end_turn"
  ), class = "ResultMessage"))
  sync_calls <- 0L
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(content) invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$approve_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }
  client$get_context_usage <- function(...) {
    sync_calls <<- sync_calls + 1L
    stop("legacy synchronous context usage must not be called")
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  events <- character(0)
  usages <- list()
  done <- FALSE
  error <- NULL
  handler(
    message = "test", thread_id = "thread-result-usage", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) {
      events <<- c(events, "done")
      done <<- TRUE
    },
    on_error = function(message) error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE)),
    on_usage = function(...) {
      events <<- c(events, "usage")
      usages[[length(usages) + 1L]] <<- list(...)
    }
  )

  for (i in seq_len(100L)) {
    later::run_now()
    if (isTRUE(done) || !is.null(error)) break
    Sys.sleep(0.002)
  }

  expect_true(done)
  expect_null(error)
  expect_identical(events, c("usage", "done"))
  expect_length(usages, 1L)
  expect_identical(usages[[1L]]$tokens, 125L)
  expect_identical(usages[[1L]]$context_tokens, NULL)
  expect_identical(usages[[1L]]$context_window, NULL)

  Sys.sleep(0.06)
  later::run_now()
  expect_identical(sync_calls, 0L)
  expect_length(usages, 1L)
})


.new_usage_probe_test_client <- function() {
  state <- new.env(parent = emptyenv())
  state$calls <- 0L
  state$controls <- list()
  client <- new.env(parent = emptyenv())
  client$get_context_usage_async <- function(timeout_ms = 5000L) {
    state$calls <- state$calls + 1L
    index <- state$calls
    promises::promise(function(resolve, reject) {
      state$controls[[index]] <- list(resolve = resolve, reject = reject)
    })
  }
  list(client = client, state = state)
}

.run_promise_callbacks <- function() {
  later::run_now()
  later::run_now()
}

test_that("async usage probe deduplicates one current thread request", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  fake <- .new_usage_probe_test_client()
  record <- new.env(parent = emptyenv())
  current <- new.env(parent = emptyenv())
  current$client <- fake$client
  current$record <- record
  current$generation <- 1L
  published <- list()
  manager <- .new_claude_usage_probe_manager(
    is_current = function(thread_id, client, consumer_record, generation) {
      identical(thread_id, "thread-a") &&
        identical(client, current$client) &&
        identical(consumer_record, current$record) &&
        identical(generation, current$generation)
    }
  )
  publish <- function(context_tokens, context_window) {
    published[[length(published) + 1L]] <<- list(
      context_tokens = context_tokens,
      context_window = context_window
    )
  }

  for (i in seq_len(4L)) {
    manager$request(
      "thread-a", fake$client, record, current$generation, publish
    )
  }
  expect_identical(fake$state$calls, 1L)
  expect_identical(manager$pending_count(), 1L)

  fake$state$controls[[1L]]$resolve(list(
    totalTokens = 321L,
    rawMaxTokens = 1000000L,
    maxTokens = 967000L
  ))
  .run_promise_callbacks()

  expect_identical(fake$state$calls, 1L)
  expect_identical(manager$pending_count(), 0L)
  expect_length(published, 1L)
  expect_identical(published[[1L]]$context_tokens, 321)
  expect_identical(published[[1L]]$context_window, 1000000L)
})

test_that("async usage probe drops an old generation and probes the latest one", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  fake <- .new_usage_probe_test_client()
  record <- new.env(parent = emptyenv())
  current_generation <- 1L
  published <- list()
  manager <- .new_claude_usage_probe_manager(
    is_current = function(thread_id, client, consumer_record, generation) {
      identical(client, fake$client) && identical(consumer_record, record) &&
        identical(generation, current_generation)
    }
  )
  publish <- function(context_tokens, context_window) {
    published[[length(published) + 1L]] <<- c(context_tokens, context_window)
  }

  manager$request("thread-b", fake$client, record, 1L, publish)
  current_generation <- 2L
  manager$request("thread-b", fake$client, record, 2L, publish)
  expect_identical(fake$state$calls, 1L)

  fake$state$controls[[1L]]$resolve(list(totalTokens = 111L, maxTokens = 200000L))
  .run_promise_callbacks()
  expect_length(published, 0L)
  expect_identical(fake$state$calls, 2L)
  expect_identical(manager$pending_count(), 1L)

  fake$state$controls[[2L]]$resolve(list(total_tokens = 222L, raw_max_tokens = 1000000L))
  .run_promise_callbacks()
  expect_length(published, 1L)
  expect_identical(unname(published[[1L]]), c(222, 1000000))
  expect_identical(manager$pending_count(), 0L)
})

test_that("async usage probe drops replacement-client responses and cleans errors", {
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  first <- .new_usage_probe_test_client()
  replacement <- .new_usage_probe_test_client()
  first_record <- new.env(parent = emptyenv())
  replacement_record <- new.env(parent = emptyenv())
  current <- new.env(parent = emptyenv())
  current$client <- first$client
  current$record <- first_record
  published <- 0L
  manager <- .new_claude_usage_probe_manager(
    is_current = function(thread_id, client, consumer_record, generation) {
      identical(client, current$client) && identical(consumer_record, current$record)
    }
  )

  manager$request(
    "thread-c", first$client, first_record, 1L,
    function(...) published <<- published + 1L
  )
  current$client <- replacement$client
  current$record <- replacement_record
  first$state$controls[[1L]]$resolve(list(totalTokens = 12L, maxTokens = 200000L))
  .run_promise_callbacks()
  expect_identical(published, 0L)
  expect_identical(manager$pending_count(), 0L)

  manager$request(
    "thread-c", replacement$client, replacement_record, 2L,
    function(...) published <<- published + 1L
  )
  replacement$state$controls[[1L]]$reject(simpleError("probe timeout"))
  .run_promise_callbacks()
  expect_identical(published, 0L)
  expect_identical(manager$pending_count(), 0L)
})


test_that("make_claude_handler refreshes Result fallback through async usage only", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("promises")
  skip_if_not_installed("later")

  queue <- list(structure(list(
    subtype = "success", duration_ms = 12, duration_api_ms = 10,
    is_error = FALSE, num_turns = 1L,
    session_id = "session-async-usage", result = "Done.",
    total_cost_usd = 0.01,
    usage = list(input_tokens = 40L, cache_read_input_tokens = 2L),
    model = list("claude-async" = list()), stop_reason = "end_turn"
  ), class = "ResultMessage"))
  async_calls <- 0L
  callback_timeout <- NULL
  control <- NULL
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$send <- function(content) invisible(NULL)
  client$deny_tool <- function(...) invisible(NULL)
  client$approve_tool <- function(...) invisible(NULL)
  client$interrupt <- function(...) invisible(NULL)
  client$poll_messages <- function() {
    current <- queue
    queue <<- list()
    current
  }
  client$get_context_usage_async <- function(timeout_ms = 5000L,
                                              on_fulfilled = NULL,
                                              on_rejected = NULL) {
    async_calls <<- async_calls + 1L
    callback_timeout <<- timeout_ms
    control <<- list(resolve = on_fulfilled, reject = on_rejected)
    invisible("usage-callback-request")
  }

  local_mocked_bindings(
    .new_claude_options = function(...) list(...),
    .new_claude_client = function(options) client
  )
  handler <- make_claude_handler(
    options = list(
      permission_mode = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages = TRUE
    ),
    session_map_path = tempfile(fileext = ".rds")
  )
  usages <- list()
  done <- FALSE
  error <- NULL
  handler_promise <- handler(
    message = "test", thread_id = "thread-async-usage", attachments = list(),
    on_chunk = function(...) NULL,
    on_done = function(...) done <<- TRUE,
    on_error = function(message) error <<- message,
    on_tool_call = function(...) NULL,
    on_tool_result = function(...) NULL,
    on_thinking = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(...) promises::promise_resolve(list(approved = FALSE)),
    on_usage = function(...) usages[[length(usages) + 1L]] <<- list(...)
  )
  handler_settled <- FALSE
  promises::then(
    handler_promise,
    onFulfilled = function(value) handler_settled <<- TRUE,
    onRejected = function(reason) handler_settled <<- TRUE
  )
  for (i in seq_len(100L)) {
    later::run_now()
    if (isTRUE(done) || !is.null(error)) break
    Sys.sleep(0.002)
  }

  expect_true(done)
  later::run_now()
  later::run_now()
  expect_true(handler_settled)
  expect_null(error)
  expect_identical(async_calls, 1L)
  expect_identical(callback_timeout, Inf)
  expect_length(usages, 1L)
  expect_null(usages[[1L]]$context_tokens)

  control$resolve(list(totalTokens = 777L, rawMaxTokens = 1000000L))
  .run_promise_callbacks()
  expect_length(usages, 2L)
  expect_identical(usages[[2L]]$tokens, 42)
  expect_identical(usages[[2L]]$context_tokens, 777)
  expect_identical(usages[[2L]]$context_window, 1000000L)
})
