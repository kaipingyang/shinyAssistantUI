test_that("Linux process memory snapshot separates PSS RSS and cgroup metrics", {
  root <- tempfile("memory-proc-")
  cgroup <- tempfile("memory-cgroup-")
  pid <- 4242L
  dir.create(file.path(root, pid), recursive = TRUE)
  dir.create(cgroup, recursive = TRUE)
  on.exit(unlink(c(root, cgroup), recursive = TRUE, force = TRUE), add = TRUE)

  writeLines(c(
    "Rss:                4096 kB",
    "Pss:                3072 kB",
    "Private_Dirty:      2048 kB",
    "Anonymous:          1024 kB"
  ), file.path(root, pid, "smaps_rollup"))
  writeLines("123456789", file.path(cgroup, "memory.current"))
  writeLines("max", file.path(cgroup, "memory.max"))
  writeLines(c("low 1", "high 2", "oom 3", "oom_kill 4"),
             file.path(cgroup, "memory.events"))

  snapshot <- .read_linux_memory_snapshot(
    pid = pid, proc_root = root, cgroup_root = cgroup,
    now = function() as.POSIXct("2026-09-14 00:00:00", tz = "UTC")
  )

  expect_identical(snapshot$available, TRUE)
  expect_identical(snapshot$source, "smaps_rollup")
  expect_identical(snapshot$rss_bytes, 4096 * 1024)
  expect_identical(snapshot$pss_bytes, 3072 * 1024)
  expect_identical(snapshot$private_dirty_bytes, 2048 * 1024)
  expect_identical(snapshot$anonymous_bytes, 1024 * 1024)
  expect_identical(snapshot$cgroup_current_bytes, 123456789)
  expect_true(is.infinite(snapshot$cgroup_max_bytes))
  expect_identical(snapshot$cgroup_events$oom_kill, 4)
})

test_that("Linux process memory snapshot falls back to status and fails open", {
  root <- tempfile("memory-status-")
  pid <- 5252L
  dir.create(file.path(root, pid), recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  writeLines(c("Name:\tR", "VmRSS:\t2048 kB"), file.path(root, pid, "status"))

  fallback <- .read_linux_memory_snapshot(
    pid = pid, proc_root = root, cgroup_root = tempfile("absent-cgroup-")
  )
  expect_true(fallback$available)
  expect_identical(fallback$source, "status")
  expect_null(fallback$pss_bytes)
  expect_identical(fallback$rss_bytes, 2048 * 1024)

  missing <- .read_linux_memory_snapshot(
    pid = 9999L, proc_root = root, cgroup_root = tempfile("absent-cgroup-")
  )
  expect_false(missing$available)
  expect_identical(missing$source, "unavailable")
  expect_null(missing$pss_bytes)
  expect_null(missing$rss_bytes)
})

test_that("Linux memory snapshot can skip expensive PSS for production sampling", {
  root <- tempfile("memory-fast-proc-")
  pid <- 6262L
  dir.create(file.path(root, pid), recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  writeLines(c("Rss: 9999 kB", "Pss: 8888 kB"), file.path(root, pid, "smaps_rollup"))
  writeLines(c("Name:\tR", "VmRSS:\t1536 kB"), file.path(root, pid, "status"))

  snapshot <- .read_linux_memory_snapshot(
    pid = pid, proc_root = root, cgroup_root = tempfile("absent-cgroup-"),
    include_pss = FALSE
  )
  expect_true(snapshot$available)
  expect_identical(snapshot$source, "status")
  expect_null(snapshot$pss_bytes)
  expect_identical(snapshot$rss_bytes, 1536 * 1024)
})

test_that("production sampler escalates from RSS to authoritative PSS near pressure", {
  root <- tempfile("memory-escalate-proc-")
  cgroup <- tempfile("memory-escalate-cgroup-")
  pid <- 7373L
  dir.create(file.path(root, pid), recursive = TRUE)
  dir.create(cgroup, recursive = TRUE)
  on.exit(unlink(c(root, cgroup), recursive = TRUE, force = TRUE), add = TRUE)
  writeLines(c("Name:\tR", "VmRSS:\t2048 kB"), file.path(root, pid, "status"))
  writeLines(c("Rss: 2048 kB", "Pss: 1536 kB"), file.path(root, pid, "smaps_rollup"))
  writeLines("123", file.path(cgroup, "memory.current"))
  writeLines("max", file.path(cgroup, "memory.max"))
  writeLines("oom_kill 0", file.path(cgroup, "memory.events"))

  sampler <- .new_linux_memory_guard_sampler(
    cgroup_every = 10L, pss_trigger_bytes = 1024 * 1024,
    pid = pid, proc_root = root, cgroup_root = cgroup
  )
  snapshot <- sampler()
  expect_identical(snapshot$source, "smaps_rollup")
  expect_identical(snapshot$pss_bytes, 1536 * 1024)
  expect_identical(snapshot$rss_bytes, 2048 * 1024)
  expect_identical(snapshot$cgroup_current_bytes, 123)
})

.fake_memory_scheduler <- function() {
  state <- new.env(parent = emptyenv())
  state$items <- list()
  state$serial <- 0L
  list(
    schedule = function(callback, delay) {
      state$serial <- state$serial + 1L
      key <- as.character(state$serial)
      item <- new.env(parent = emptyenv())
      item$callback <- callback
      item$delay <- delay
      item$cancelled <- FALSE
      state$items[[key]] <- item
      function() item$cancelled <- TRUE
    },
    run_next = function() {
      keys <- names(state$items)
      for (key in keys) {
        item <- state$items[[key]]
        state$items[[key]] <- NULL
        if (!isTRUE(item$cancelled)) {
          item$callback()
          return(invisible(item$delay))
        }
      }
      invisible(NULL)
    },
    pending = function() sum(vapply(
      state$items, function(item) !isTRUE(item$cancelled), logical(1)
    ))
  )
}

.memory_sample <- function(pss) list(
  available = TRUE,
  source = "smaps_rollup",
  pss_bytes = as.numeric(pss),
  rss_bytes = as.numeric(pss) + 10,
  captured_at = Sys.time()
)

.memory_guard_test_config <- function() list(
  enabled = TRUE,
  soft_pss_bytes = 100,
  hard_pss_bytes = 200,
  soft_rss_bytes = 125,
  hard_rss_bytes = 225,
  consecutive_samples = 2L,
  hysteresis = 0.8,
  active_interval = 1,
  idle_interval = 5,
  settle_delay = 2
)

test_that("memory guard enters hard pending while active and hard idle after settle", {
  samples <- list(.memory_sample(210), .memory_sample(220), .memory_sample(215))
  sample_index <- 0L
  busy <- TRUE
  gc_calls <- 0L
  scheduler <- .fake_memory_scheduler()
  guard <- .new_memory_pressure_guard(
    sample = function() {
      sample_index <<- sample_index + 1L
      samples[[sample_index]]
    },
    busy_snapshot = function() list(busy = busy),
    gc_full = function() gc_calls <<- gc_calls + 1L,
    schedule = scheduler$schedule,
    config = .memory_guard_test_config()
  )

  guard$observe()
  expect_identical(guard$snapshot()$state, "normal")
  guard$observe()
  expect_identical(guard$snapshot()$state, "hard_pending")
  expect_false(guard$allows("foreground"))
  expect_false(guard$allows("compact"))
  expect_false(guard$allows("proactive"))
  expect_true(guard$allows("approval"))
  expect_true(guard$allows("interrupt"))
  expect_identical(gc_calls, 0L)

  busy <- FALSE
  guard$on_idle()
  expect_identical(gc_calls, 1L)
  expect_identical(guard$snapshot()$settling, TRUE)
  expect_identical(scheduler$pending(), 1L)
  scheduler$run_next()

  expect_identical(guard$snapshot()$state, "hard_idle")
  expect_false(guard$allows("foreground"))
  expect_false(guard$allows("resume"))
  expect_true(guard$allows("terminal_drain"))
  expect_identical(gc_calls, 1L)
})

test_that("memory guard recovers after idle GC only below hard hysteresis", {
  samples <- list(.memory_sample(210), .memory_sample(220), .memory_sample(150))
  sample_index <- 0L
  busy <- TRUE
  scheduler <- .fake_memory_scheduler()
  guard <- .new_memory_pressure_guard(
    sample = function() {
      sample_index <<- sample_index + 1L
      samples[[sample_index]]
    },
    busy_snapshot = function() list(busy = busy),
    gc_full = function() invisible(NULL),
    schedule = scheduler$schedule,
    config = .memory_guard_test_config()
  )

  guard$observe(); guard$observe()
  busy <- FALSE
  guard$on_idle()
  scheduler$run_next()

  expect_identical(guard$snapshot()$state, "soft")
  expect_true(guard$allows("foreground"))
  expect_false(guard$snapshot()$gc_attempted)
})

test_that("memory guard hard idle is sticky and disposal invalidates callbacks", {
  samples <- list(.memory_sample(210), .memory_sample(220), .memory_sample(220))
  sample_index <- 0L
  scheduler <- .fake_memory_scheduler()
  guard <- .new_memory_pressure_guard(
    sample = function() {
      sample_index <<- sample_index + 1L
      samples[[min(sample_index, length(samples))]]
    },
    busy_snapshot = function() list(busy = FALSE),
    gc_full = function() invisible(NULL),
    schedule = scheduler$schedule,
    config = .memory_guard_test_config()
  )

  guard$observe(); guard$observe()
  expect_true(scheduler$pending() >= 1L)
  guard$dispose()
  before <- guard$snapshot()
  scheduler$run_next()
  after <- guard$snapshot()

  expect_true(after$disposed)
  expect_identical(after$generation, before$generation)
  expect_identical(after$state, before$state)
  expect_false(guard$start())
})

test_that("memory guard requires consecutive samples and clears soft with hysteresis", {
  samples <- list(
    .memory_sample(110), .memory_sample(90),
    .memory_sample(110), .memory_sample(115),
    .memory_sample(70), .memory_sample(75)
  )
  index <- 0L
  guard <- .new_memory_pressure_guard(
    sample = function() { index <<- index + 1L; samples[[index]] },
    busy_snapshot = function() list(busy = FALSE),
    gc_full = function() invisible(NULL),
    schedule = .fake_memory_scheduler()$schedule,
    config = .memory_guard_test_config()
  )

  guard$observe(); expect_identical(guard$snapshot()$state, "normal")
  guard$observe(); expect_identical(guard$snapshot()$state, "normal")
  guard$observe(); guard$observe(); expect_identical(guard$snapshot()$state, "soft")
  guard$observe(); expect_identical(guard$snapshot()$state, "soft")
  guard$observe(); expect_identical(guard$snapshot()$state, "normal")
})


test_that("memory guard observation reuses samples and cannot affect state", {
  samples <- list(.memory_sample(210), .memory_sample(220))
  index <- 0L
  observations <- list()
  guard <- .new_memory_pressure_guard(
    sample = function() {
      index <<- index + 1L
      samples[[index]]
    },
    busy_snapshot = function() list(busy = TRUE),
    gc_full = function() invisible(NULL),
    schedule = .fake_memory_scheduler()$schedule,
    config = .memory_guard_test_config(),
    on_observation = function(sample, previous_state, next_state) {
      observations[[length(observations) + 1L]] <<- list(
        sample = sample,
        previous_state = previous_state,
        next_state = next_state
      )
    }
  )

  guard$observe()
  guard$observe()

  expect_identical(index, 2L)
  expect_length(observations, 2L)
  expect_identical(observations[[1L]]$previous_state, "normal")
  expect_identical(observations[[1L]]$next_state, "normal")
  expect_identical(observations[[2L]]$previous_state, "normal")
  expect_identical(observations[[2L]]$next_state, "hard_pending")
  expect_identical(observations[[2L]]$sample$pss_bytes, 220)

  throwing <- .new_memory_pressure_guard(
    sample = function() .memory_sample(110),
    busy_snapshot = function() list(busy = FALSE),
    gc_full = function() invisible(NULL),
    schedule = .fake_memory_scheduler()$schedule,
    config = .memory_guard_test_config(),
    on_observation = function(...) stop("observer must be fail-open")
  )
  expect_true(throwing$observe())
  expect_identical(throwing$snapshot()$state, "normal")
})
