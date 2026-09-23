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

test_that("memory monitor advertises v4 latest-snapshot capability", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  expect_identical(plugin$config(), list(
    version = 4L, protocol = "latest-snapshot"
  ))
  bound <- bind_memory_v2(plugin, "chat_input")
  expect_named(bound$binding$config, c("version", "ownerSeed", "lastRevision"))
  expect_identical(bound$binding$config$version, 4L)
  expect_gt(bound$binding$config$ownerSeed, 0)
})

test_that("memory v2 sends one exact frozen snapshot per opening", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "chat_input")
  plugin$observe(list(
    pss_bytes = 80, rss_bytes = 90,
    tree_rss_bytes = 260, tree_process_count = 3L,
    cgroup_current_bytes = 2465 * 1024^2,
    cgroup_max_bytes = 29296 * 1024^2,
    prompt = "SECRET", path = "/PRIVATE", pid = 123
  ), "normal", "normal")
  bound$input(memory_open(bound$binding, 1, TRUE))
  expect_length(bound$sent(), 1L)
  frame <- bound$sent()[[1L]]$message
  expect_named(frame, c("version", "ownerId", "openId", "revision", "sample"))
  expect_named(frame$sample, c(
    "state", "pssBytes", "rssBytes", "treeRssBytes", "treeProcessCount",
    "cgroupCurrentBytes", "cgroupMaxBytes",
    "cgroupLimited", "softPssBytes", "hardPssBytes", "softRssBytes", "hardRssBytes"
  ))
  expect_identical(frame$sample$state, "normal")
  expect_identical(frame$sample$pssBytes, 80)
  expect_identical(frame$sample$treeRssBytes, 260)
  expect_identical(frame$sample$treeProcessCount, 3)
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

test_that("memory v3 exposes real sample times and keeps cached refreshes honest", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "timed_input")
  expect_identical(bound$binding$config$version, 4L)
  captured <- as.POSIXct("2026-09-18 09:17:43", tz = "UTC")
  plugin$observe(list(
    pss_bytes = 80, rss_bytes = 90,
    captured_at = captured,
    tree_captured_at = captured - 10,
    cgroup_captured_at = captured - 10,
    cgroup_stat = list(anon = 60, file = 40)
  ), "normal", "normal")
  request <- memory_open(bound$binding, 1, TRUE)
  request$version <- 3L
  bound$input(request)
  expect_length(bound$sent(), 1L)
  if (!length(bound$sent())) return(invisible(NULL))
  frame <- bound$sent()[[1L]]$message
  expect_identical(frame$version, 3L)
  expect_false("session" %in% names(frame$sample))
  expect_identical(frame$sample$sampledAt, as.numeric(captured) * 1000)
  expect_identical(frame$sample$treeSampledAt, as.numeric(captured - 10) * 1000)
  expect_identical(frame$sample$cgroupSampledAt, as.numeric(captured - 10) * 1000)
  request$openId <- 2
  request$revision <- frame$revision
  bound$input(request)
  expect_length(bound$sent(), 2L)
  expect_identical(bound$sent()[[2L]]$message$sample, frame$sample)
  expect_identical(bound$sent()[[2L]]$message$revision, frame$revision)
})

memory_v4_sample <- function(at, events = list(max = 12529, oom = 0, oom_kill = 0)) list(
  pss_bytes = 300 * 1024^2, rss_bytes = 335 * 1024^2,
  captured_at = at, cgroup_captured_at = at,
  cgroup_current_bytes = 28 * 1024^3, cgroup_max_bytes = 30 * 1024^3,
  cgroup_stat = list(anon = 1.75 * 1024^3, file = 26.25 * 1024^3,
                     inactive_file = 26 * 1024^3, shmem = 0,
                     file_dirty = 0, file_writeback = 0, private_path = "/PRIVATE"),
  cgroup_events = events,
  cgroup_pressure = list(some = 0.25, full = 0, private_prompt = "SECRET")
)

memory_v4_reader <- function(bound) {
  opening <- 0
  revision <- 0
  function() {
    opening <<- opening + 1
    request <- memory_open(bound$binding, opening, TRUE, revision)
    request$version <- 4L
    bound$input(request)
    expect_length(bound$sent(), opening)
    frame <- bound$sent()[[opening]]$message
    revision <<- frame$revision
    frame$sample
  }
}

test_that("memory v4 sends only allowlisted session fields with explicit nulls", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "breakdown_input")
  read <- memory_v4_reader(bound)
  at <- as.POSIXct("2026-09-22 09:00:00", tz = "UTC")
  plugin$observe(memory_v4_sample(at), "normal", "normal")
  sample <- read()
  expect_identical(bound$sent()[[1L]]$message$version, 4L)
  expect_identical(sample$session, list(
    currentAvailable = TRUE, limitKind = "limited",
    anonBytes = 1.75 * 1024^3, fileBytes = 26.25 * 1024^3,
    inactiveFileBytes = 26 * 1024^3, shmemBytes = 0,
    dirtyFileBytes = 0, writebackFileBytes = 0,
    limitEvents = 12529, oomEvents = 0, oomKillEvents = 0,
    limitEventsDelta = NULL, oomEventsDelta = NULL, oomKillEventsDelta = NULL,
    intervalMs = NULL, psiSomeAvg10 = 0.25, psiFullAvg10 = 0
  ))
  wire <- jsonlite::toJSON(sample, auto_unbox = TRUE, null = "null")
  expect_match(wire, '"limitEventsDelta":null', fixed = TRUE)
  expect_false(grepl("SECRET|PRIVATE|private_", wire))
  expect_identical(read(), sample)
})

test_that("session counter deltas follow actual samples, not refreshes or fast RSS ticks", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "delta_input")
  read <- memory_v4_reader(bound)
  at <- as.POSIXct("2026-09-22 09:00:00", tz = "UTC")
  plugin$observe(memory_v4_sample(at), "normal", "normal")
  expect_null(read()$session$intervalMs)
  sample <- memory_v4_sample(at + 10, list(max = 12532, oom = 1, oom_kill = 0))
  plugin$observe(sample, "normal", "normal")
  delta <- read()$session
  expect_identical(delta$intervalMs, 10000)
  expect_identical(delta$limitEventsDelta, 3)
  expect_identical(delta$oomEventsDelta, 1)
  expect_identical(delta$oomKillEventsDelta, 0)
  sample$captured_at <- at + 15
  plugin$observe(sample, "normal", "normal")
  expect_identical(read()$session, delta)
  expect_identical(read()$session, delta)

  plugin$observe(memory_v4_sample(at + 20, list(max = 2, oom = 2, oom_kill = 0)),
                 "normal", "normal")
  reset <- read()$session
  expect_null(reset$limitEventsDelta)
  expect_identical(reset$oomEventsDelta, 1)
  expect_identical(reset$intervalMs, 10000)
  plugin$observe(memory_v4_sample(at + 19), "normal", "normal")
  rollback <- read()$session
  expect_null(rollback$intervalMs)
  expect_null(rollback$limitEventsDelta)
  sample$cgroup_captured_at <- NULL
  plugin$observe(sample, "normal", "normal")
  missing <- read()$session
  expect_null(missing$intervalMs)
  expect_null(missing$oomEventsDelta)
  plugin$observe(memory_v4_sample(at + 30), "normal", "normal")
  expect_null(read()$session$intervalMs)
})

test_that("session unavailable fields differ from valid zero and explicit unlimited", {
  plugin <- shinyAssistantUI:::.new_memory_monitor_addin_plugin(memory_v2_config())
  on.exit(plugin$dispose(), add = TRUE)
  bound <- bind_memory_v2(plugin, "missing_input")
  read <- memory_v4_reader(bound)
  plugin$observe(list(), "normal", "normal")
  missing <- read()$session
  expect_false(missing$currentAvailable)
  expect_identical(missing$limitKind, "unknown")
  expect_true(all(vapply(missing[-c(1L, 2L)], is.null, logical(1))))

  plugin$observe(list(
    cgroup_current_bytes = 0, cgroup_max_bytes = Inf,
    cgroup_stat = list(anon = -1, file = 1.5, inactive_file = 2^53,
                       shmem = "0", file_dirty = NA_real_, file_writeback = 0),
    cgroup_events = list(max = -1, oom = Inf, oom_kill = 0),
    cgroup_pressure = list(some = 101, full = 0)
  ), "normal", "normal")
  zero <- read()$session
  expect_true(zero$currentAvailable)
  expect_identical(zero$limitKind, "unlimited")
  for (field in c("anonBytes", "fileBytes", "inactiveFileBytes", "shmemBytes",
                  "dirtyFileBytes", "limitEvents", "oomEvents", "psiSomeAvg10"))
    expect_null(zero[[field]])
  expect_identical(zero$writebackFileBytes, 0)
  expect_identical(zero$oomKillEvents, 0)
  expect_identical(zero$psiFullAvg10, 0)
})
