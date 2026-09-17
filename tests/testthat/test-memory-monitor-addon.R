memory_v2_config <- function() list(
  enabled = TRUE, soft_pss_bytes = 100, hard_pss_bytes = 200,
  soft_rss_bytes = 125, hard_rss_bytes = 225,
  consecutive_samples = 2L, hysteresis = 0.8,
  active_interval = 1, idle_interval = 5, settle_delay = 2
)

bind_memory_v2 <- function(plugin, input_id) {
  session <- shiny::MockShinySession$new()
  sent <- list()
  session$sendCustomMessage <- function(type, message) {
    sent[[length(sent) + 1L]] <<- list(type = type, message = message)
  }
  binding <- shiny::withReactiveDomain(session, plugin$bind(session, input_id))
  session$flushReact()
  input <- function(value) {
    args <- list(value); names(args) <- paste0(input_id, "_memory_monitor_visible")
    do.call(session$setInputs, args); session$flushReact()
  }
  list(session = session, binding = binding, sent = function() sent,
       clear = function() sent <<- list(), input = input)
}

memory_open <- function(binding, open_id, visible, revision = 0) list(
  version = 2L, ownerId = binding$config$ownerSeed, openId = open_id,
  visible = visible, revision = revision, sample = NULL
)

test_that("memory monitor advertises v2 latest-snapshot capability", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  expect_identical(plugin$config(), list(
    version = 2L, protocol = "latest-snapshot"
  ))
  bound <- bind_memory_v2(plugin, "chat_input")
  expect_named(bound$binding$config, c("version", "ownerSeed", "lastRevision"))
  expect_identical(bound$binding$config$version, 2L)
  expect_gt(bound$binding$config$ownerSeed, 0)
})

test_that("memory v2 sends one exact frozen snapshot per opening", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  plugin$observe(list(
    pss_bytes = 80, rss_bytes = 90,
    cgroup_current_bytes = 2465 * 1024^2,
    cgroup_max_bytes = 29296 * 1024^2,
    prompt = "SECRET", path = "/PRIVATE", pid = 123
  ), "normal", "normal")
  bound$input(memory_open(bound$binding, 1, TRUE))
  expect_length(bound$sent(), 1L)
  frame <- bound$sent()[[1L]]$message
  expect_named(frame, c("version", "ownerId", "openId", "revision", "sample"))
  expect_named(frame$sample, c(
    "state", "pssBytes", "rssBytes", "cgroupCurrentBytes", "cgroupMaxBytes",
    "cgroupLimited", "softPssBytes", "hardPssBytes", "softRssBytes", "hardRssBytes"
  ))
  expect_identical(frame$sample$state, "normal")
  expect_identical(frame$sample$pssBytes, 80)
  expect_identical(frame$sample$cgroupCurrentBytes, 2465 * 1024^2)
  expect_identical(frame$sample$cgroupMaxBytes, 29296 * 1024^2)
  expect_true(frame$sample$cgroupLimited)
  expect_false(grepl("SECRET|PRIVATE|123", paste(capture.output(str(frame)), collapse = "")))

  plugin$observe(list(pss_bytes = 150, rss_bytes = 160), "normal", "soft")
  expect_length(bound$sent(), 1L)
  bound$input(memory_open(bound$binding, 1, FALSE, frame$revision))
  bound$input(memory_open(bound$binding, 2, TRUE, frame$revision))
  expect_length(bound$sent(), 2L)
  expect_identical(bound$sent()[[2L]]$message$sample$state, "soft")
  expect_identical(bound$sent()[[2L]]$message$openId, 2)
})

test_that("memory opening with no latest waits for one real observation", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  bound$input(memory_open(bound$binding, 1, TRUE))
  expect_length(bound$sent(), 0L)
  plugin$observe(list(pss_bytes = 100, rss_bytes = 110), "normal", "soft")
  expect_length(bound$sent(), 1L)
  plugin$observe(list(pss_bytes = 200, rss_bytes = 210), "soft", "hard_pending")
  expect_length(bound$sent(), 1L)
})

test_that("memory v2 hard aliases normalize and sessions have independent owners", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  a <- bind_memory_v2(plugin, "a_input")
  b <- bind_memory_v2(plugin, "b_input")
  expect_false(identical(a$binding$config$ownerSeed, b$binding$config$ownerSeed))
  for (state in c("hard_pending", "hard_idle", "hard")) {
    plugin$observe(list(pss_bytes = 201, rss_bytes = 226), "soft", state)
    open_id <- plugin$snapshot()$revision
    a$input(memory_open(a$binding, open_id, TRUE))
    expect_identical(tail(a$sent(), 1L)[[1L]]$message$sample$state, "hard")
    a$input(memory_open(a$binding, open_id, FALSE,
                        tail(a$sent(), 1L)[[1L]]$message$revision))
  }
  b$input(memory_open(b$binding, 1, TRUE))
  expect_length(b$sent(), 1L)
  a$session$close()
  expect_identical(plugin$snapshot()$bindings, 1L)
})

test_that("memory v1, wrong owner, unknown keys and duplicate openings are inert", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  plugin$observe(list(pss_bytes = 80, rss_bytes = 90), "normal", "normal")
  bound$input(list(visible = TRUE))
  rebound <- memory_open(bound$binding, 1, FALSE)
  rebound$ownerId <- rebound$ownerId + 1
  bound$input(rebound)
  stale_owner <- memory_open(bound$binding, 1, TRUE)
  bound$input(stale_owner)
  extra <- memory_open(bound$binding, 1, TRUE)
  extra$ownerId <- rebound$ownerId
  extra$path <- "/PRIVATE"
  bound$input(extra)
  expect_length(bound$sent(), 0L)
  good <- memory_open(bound$binding, 1, TRUE)
  good$ownerId <- rebound$ownerId
  bound$input(good)
  bound$input(good)
  expect_length(bound$sent(), 1L)
})

test_that("collapsed observations coalesce to latest revision without pushes", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  for (revision in seq_len(25L)) {
    plugin$observe(list(pss_bytes = revision, rss_bytes = revision + 10),
                   "normal", "normal")
  }
  expect_length(bound$sent(), 0L)
  bound$input(memory_open(bound$binding, 1, TRUE))
  expect_length(bound$sent(), 1L)
  expect_identical(bound$sent()[[1L]]$message$revision, 25)
  expect_identical(bound$sent()[[1L]]$message$sample$pssBytes, 25)
})

test_that("memory observation callback is fail-open", {
  sample <- list(pss_bytes = 1, rss_bytes = 2)
  captured <- NULL
  expect_true(shinyAssistantUI:::.notify_memory_observation(
    function(sample, previous_state, next_state) {
      captured <<- list(sample, previous_state, next_state)
    }, sample, "normal", "soft"
  ))
  expect_identical(captured, list(sample, "normal", "soft"))
  expect_false(shinyAssistantUI:::.notify_memory_observation(
    function(...) stop("PRIVATE-CONDITION"), sample, "soft", "hard_pending"
  ))
})


test_that("memory binding adopts a higher remount owner and rejects the old owner", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  plugin$observe(list(pss_bytes = 90, rss_bytes = 100), "normal", "normal")
  initial_owner <- bound$binding$config$ownerSeed
  remount <- memory_open(bound$binding, 1, TRUE)
  remount$ownerId <- initial_owner + 1
  bound$input(remount)

  expect_length(bound$sent(), 1L)
  expect_identical(bound$sent()[[1L]]$message$ownerId, initial_owner + 1)
  expect_identical(bound$sent()[[1L]]$message$openId, 1)

  stale <- memory_open(bound$binding, 2, TRUE)
  stale$ownerId <- initial_owner
  bound$input(stale)
  expect_length(bound$sent(), 1L)
  expect_identical(plugin$snapshot()$last_owner, initial_owner + 1)
})
