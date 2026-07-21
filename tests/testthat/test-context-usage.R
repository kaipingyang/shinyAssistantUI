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
  client <- new.env(parent = emptyenv())
  client$connect <- function() invisible(NULL)
  client$disconnect <- function() invisible(NULL)
  client$get_context_usage <- function() usage

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
