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
  writeLines(c("anon 1234", "file 4096", "inactive_file 3072", "shmem 128",
               "file_dirty 0", "file_writeback 64"),
             file.path(cgroup, "memory.stat"))
  writeLines(c(
    "some avg10=1.25 avg60=0.50 avg300=0.10 total=12345",
    "full avg10=0.00 avg60=0.00 avg300=0.00 total=12"
  ), file.path(cgroup, "memory.pressure"))

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
  expect_identical(snapshot$cgroup_stat, list(
    anon = 1234, file = 4096, inactive_file = 3072, shmem = 128,
    file_dirty = 0, file_writeback = 64
  ))
  expect_identical(snapshot$cgroup_pressure, list(some = 1.25, full = 0))
})

test_that("PSI preserves valid zero and does not turn missing or invalid data into zero", {
  path <- tempfile("memory-pressure-")
  on.exit(unlink(path), add = TRUE)
  expect_identical(.memory_parse_pressure(path), list(some = NULL, full = NULL))
  for (invalid in c("-1", "101", "NaN", "Inf", "bad")) {
    writeLines(c(paste0("some avg10=", invalid, " avg60=0 total=0"),
                 "full avg60=0 avg300=0 total=0"), path)
    expect_identical(.memory_parse_pressure(path), list(some = NULL, full = NULL))
  }
  writeLines(c("some avg10=0.00 avg60=0 total=0", "full avg10=100.00 total=1"), path)
  expect_identical(.memory_parse_pressure(path), list(some = 0, full = 100))
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

.memory_sample <- function(pss, cgroup_current = NULL, cgroup_max = NULL) list(
  available = TRUE,
  source = "smaps_rollup",
  pss_bytes = as.numeric(pss),
  rss_bytes = as.numeric(pss) + 10,
  cgroup_current_bytes = cgroup_current,
  cgroup_max_bytes = cgroup_max,
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


test_that("process hard pressure warns but does not block explicit work when cgroup has headroom", {
  samples <- list(
    .memory_sample(210, .memory_guard_gib(2), .memory_guard_gib(10)),
    .memory_sample(220, .memory_guard_gib(2), .memory_guard_gib(10))
  )
  index <- 0L
  guard <- .new_memory_pressure_guard(
    sample = function() { index <<- index + 1L; samples[[index]] },
    busy_snapshot = function() list(busy = TRUE),
    gc_full = function() invisible(NULL),
    schedule = .fake_memory_scheduler()$schedule,
    config = .memory_guard_test_config()
  )
  guard$observe(); guard$observe()
  expect_identical(guard$snapshot()$state, "hard_pending")
  expect_true(guard$allows("foreground"))
  expect_true(guard$allows("compact"))
  expect_true(guard$allows("resume"))
  expect_true(guard$allows("reload"))
  expect_false(guard$allows("warmup"))
  expect_false(guard$allows("proactive"))
  expect_false(guard$allows("auto_continue"))
})

test_that("cgroup critical pressure still blocks explicit model work", {
  samples <- list(
    .memory_sample(210, .memory_guard_gib(9.5), .memory_guard_gib(10)),
    .memory_sample(220, .memory_guard_gib(9.5), .memory_guard_gib(10))
  )
  index <- 0L
  guard <- .new_memory_pressure_guard(
    sample = function() { index <<- index + 1L; samples[[index]] },
    busy_snapshot = function() list(busy = TRUE),
    gc_full = function() invisible(NULL),
    schedule = .fake_memory_scheduler()$schedule,
    config = .memory_guard_test_config()
  )
  guard$observe(); guard$observe()
  expect_false(guard$allows("foreground"))
  expect_false(guard$allows("resume"))
  expect_true(guard$allows("approval"))
})

test_that("hard idle re-evaluates later samples and can recover", {
  samples <- list(
    .memory_sample(210, .memory_guard_gib(2), .memory_guard_gib(10)),
    .memory_sample(220, .memory_guard_gib(2), .memory_guard_gib(10)),
    .memory_sample(220, 20, 100),
    .memory_sample(150, 20, 100)
  )
  index <- 0L
  scheduler <- .fake_memory_scheduler()
  guard <- .new_memory_pressure_guard(
    sample = function() { index <<- index + 1L; samples[[index]] },
    busy_snapshot = function() list(busy = FALSE),
    gc_full = function() invisible(NULL),
    schedule = scheduler$schedule,
    config = .memory_guard_test_config()
  )
  guard$observe(); guard$observe()
  scheduler$run_next()
  expect_identical(guard$snapshot()$state, "hard_idle")
  guard$observe()
  expect_identical(guard$snapshot()$state, "soft")
  expect_true(guard$allows("foreground"))
})


test_that("guard GC tracker captures post-GC heap without an extra collection", {
  calls <- 0L
  result <- matrix(0, nrow = 2L, ncol = 6L,
                   dimnames = list(c("Ncells", "Vcells"),
                                   c("used", "(Mb)", "gc trigger", "(Mb)", "max used", "(Mb)")))
  result[, 2L] <- c(12.5, 37.25)
  tracker <- shinyAssistantUI:::.new_memory_guard_gc_tracker(function() {
    calls <<- calls + 1L
    result
  })

  expect_identical(tracker$snapshot(), list(
    r_heap_after_gc_bytes = 0,
    guard_gc_count = 0
  ))
  tracker$collect()
  expect_identical(calls, 1L)
  expect_identical(tracker$snapshot(), list(
    r_heap_after_gc_bytes = round((12.5 + 37.25) * 1024^2),
    guard_gc_count = 1
  ))
})

test_that("process tree RSS sums the addin R process and its transitive children", {
  root <- tempfile("memory-tree-")
  pid <- 4242L
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  write_proc <- function(p, rss_kib, children = integer()) {
    dir.create(file.path(root, p, "task", p), recursive = TRUE)
    writeLines(c("Name:\tR", paste0("VmRSS:\t", rss_kib, " kB")),
               file.path(root, p, "status"))
    writeLines(paste(children, collapse = " "),
               file.path(root, p, "task", p, "children"))
  }
  write_proc(pid, 2048, c(100L, 200L))
  write_proc(100L, 512, integer())
  write_proc(200L, 1024, 300L)
  write_proc(300L, 256, integer())

  tree <- .read_process_tree_rss(pid = pid, proc_root = root)
  expect_identical(tree$bytes, (2048 + 512 + 1024 + 256) * 1024)
  expect_identical(tree$count, 4L)
})

test_that("process tree RSS fails open and stays bounded", {
  root <- tempfile("memory-tree-open-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  write_status <- function(p, rss_kib) {
    dir.create(file.path(root, p, "task", p), recursive = TRUE)
    writeLines(c("Name:\tR", paste0("VmRSS:\t", rss_kib, " kB")),
               file.path(root, p, "status"))
  }

  # No children file at all: the tree collapses to the process itself.
  write_status(700L, 4096)
  alone <- .read_process_tree_rss(pid = 700L, proc_root = root)
  expect_identical(alone$bytes, 4096 * 1024)
  expect_identical(alone$count, 1L)

  # A child listed but already gone contributes nothing and does not error.
  writeLines("701", file.path(root, 700L, "task", 700L, "children"))
  vanished <- .read_process_tree_rss(pid = 700L, proc_root = root)
  expect_identical(vanished$bytes, 4096 * 1024)
  expect_identical(vanished$count, 1L)

  # A cycle terminates instead of recursing forever.
  write_status(800L, 1024)
  write_status(801L, 1024)
  writeLines("801", file.path(root, 800L, "task", 800L, "children"))
  writeLines("800", file.path(root, 801L, "task", 801L, "children"))
  cyclic <- .read_process_tree_rss(pid = 800L, proc_root = root)
  expect_identical(cyclic$bytes, 2048 * 1024)
  expect_identical(cyclic$count, 2L)

  # An entirely absent process yields NULL rather than a wrong number.
  expect_null(.read_process_tree_rss(pid = 9999L, proc_root = root))
})

test_that("memory snapshot exposes process tree RSS alongside single-process metrics", {
  root <- tempfile("memory-snapshot-tree-")
  pid <- 4343L
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  dir.create(file.path(root, pid, "task", pid), recursive = TRUE)
  writeLines(c("Rss:  4096 kB", "Pss:  3072 kB"), file.path(root, pid, "smaps_rollup"))
  writeLines(c("Name:\tR", "VmRSS:\t4096 kB"), file.path(root, pid, "status"))
  writeLines("900", file.path(root, pid, "task", pid, "children"))
  dir.create(file.path(root, 900L, "task", 900L), recursive = TRUE)
  writeLines(c("Name:\tclaude", "VmRSS:\t8192 kB"), file.path(root, 900L, "status"))

  snapshot <- .read_linux_memory_snapshot(
    pid = pid, proc_root = root, cgroup_root = tempfile("absent-cgroup-")
  )
  expect_identical(snapshot$rss_bytes, 4096 * 1024)
  expect_identical(snapshot$tree_rss_bytes, (4096 + 8192) * 1024)
  expect_identical(snapshot$tree_process_count, 2L)
})

test_that("production sampler throttles the process tree walk with cgroup", {
  root <- tempfile("memory-throttle-")
  pid <- 5150L
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  cgroup <- file.path(root, "cgroup")
  dir.create(file.path(root, pid, "task", pid), recursive = TRUE)
  dir.create(file.path(root, 6000L, "task", 6000L), recursive = TRUE)
  dir.create(cgroup, recursive = TRUE)
  writeLines(c("Name:\tR", "VmRSS:\t4096 kB"), file.path(root, pid, "status"))
  writeLines("6000", file.path(root, pid, "task", pid, "children"))
  writeLines(c("Name:\tclaude", "VmRSS:\t2048 kB"), file.path(root, 6000L, "status"))
  writeLines("2048", file.path(cgroup, "memory.current"))
  writeLines("max", file.path(cgroup, "memory.max"))

  sampler <- .new_linux_memory_guard_sampler(
    pid = pid, proc_root = root, cgroup_root = cgroup, cgroup_every = 3L
  )
  first <- sampler()
  expect_identical(first$tree_rss_bytes, (4096 + 2048) * 1024)
  expect_identical(first$tree_process_count, 2L)

  # The child disappears; the throttled tick keeps serving the cached tree value.
  unlink(file.path(root, 6000L), recursive = TRUE, force = TRUE)
  second <- sampler()
  expect_identical(second$tree_rss_bytes, (4096 + 2048) * 1024)
  expect_identical(second$tree_process_count, 2L)

  # Refresh ticks are count 1, 3, 6, ... so the third call walks again and sees
  # the tree shrink; the following throttled tick reuses that fresher value.
  third <- sampler()
  expect_identical(third$tree_rss_bytes, 4096 * 1024)
  expect_identical(third$tree_process_count, 1L)
  fourth <- sampler()
  expect_identical(fourth$tree_rss_bytes, 4096 * 1024)
  expect_identical(fourth$tree_process_count, 1L)
})

test_that("a pending usage probe does not starve full GC but real work still defers it", {
  make_guard <- function(snapshot_fn) {
    collected <- 0L
    pending <- list()
    guard <- .new_memory_pressure_guard(
      sample = function() list(
        available = TRUE, source = "test", rss_bytes = 3 * 1024^3, pss_bytes = NULL
      ),
      busy_snapshot = snapshot_fn,
      gc_full = function() { collected <<- collected + 1L; invisible(NULL) },
      schedule = function(callback, delay) {
        pending[[length(pending) + 1L]] <<- callback
        function() invisible(TRUE)
      },
      config = list(enabled = TRUE, consecutive_samples = 1L,
                    soft_rss_bytes = 1024^3, hard_rss_bytes = 2 * 1024^3)
    )
    list(guard = guard, collected = function() collected)
  }

  # A probe in flight is a lightweight IPC round-trip, not R work: GC must still run.
  probe_only <- make_guard(function() list(busy = TRUE, gc_blocked = FALSE))
  probe_only$guard$observe()
  expect_identical(probe_only$collected(), 1L)

  # Real R work (an active turn, compaction, ...) must still defer the collection.
  real_work <- make_guard(function() list(busy = TRUE, gc_blocked = TRUE))
  real_work$guard$observe()
  expect_identical(real_work$collected(), 0L)

  # A snapshot without the new field keeps the old meaning (back-compat).
  legacy <- make_guard(function() list(busy = TRUE))
  legacy$guard$observe()
  expect_identical(legacy$collected(), 0L)
})

test_that("started guard keeps one ticker after every GC settlement outcome", {
  for (outcome in c("high", "recovered", "unavailable", "busy")) {
    scheduler <- .fake_memory_scheduler()
    reads <- collections <- 0L
    busy <- FALSE
    guard <- .new_memory_pressure_guard(
      sample = function() {
        reads <<- reads + 1L
        if (reads >= 3L && outcome == "unavailable") return(list(available = FALSE))
        if (reads >= 3L && outcome == "recovered") return(.memory_sample(50))
        .memory_sample(220)
      },
      busy_snapshot = function() list(busy = busy),
      gc_full = function() collections <<- collections + 1L,
      schedule = scheduler$schedule,
      config = .memory_guard_test_config()
    )
    guard$start()
    scheduler$run_next()
    scheduler$run_next()
    expect_true(guard$snapshot()$settling, info = outcome)
    if (outcome == "busy") busy <- TRUE
    scheduler$run_next()
    expect_false(guard$snapshot()$settling, info = outcome)
    expect_identical(scheduler$pending(), 1L, info = outcome)
    expect_identical(collections, 1L, info = outcome)
    expect_identical(
      guard$snapshot()$state,
      if (outcome == "recovered") "normal" else "hard_idle",
      info = outcome
    )
    scheduler$run_next()
    scheduler$run_next()
    expect_identical(reads, 5L, info = outcome)
    expect_identical(scheduler$pending(), 1L, info = outcome)
    expect_identical(collections, 1L, info = outcome)
    guard$dispose()
    expect_identical(scheduler$pending(), 0L, info = outcome)
  }
})

test_that("cancelled ticks cannot replace a newer settle or restart a disposed guard", {
  callbacks <- list()
  reads <- 0L
  guard <- .new_memory_pressure_guard(
    sample = function() { reads <<- reads + 1L; .memory_sample(220) },
    busy_snapshot = function() list(busy = FALSE),
    gc_full = function() invisible(NULL),
    schedule = function(callback, delay) {
      callbacks[[length(callbacks) + 1L]] <<- callback
      function() invisible(NULL)
    },
    config = .memory_guard_test_config()
  )
  guard$start()
  stale_tick <- callbacks[[1L]]
  guard$observe()
  guard$observe()
  settle <- callbacks[[2L]]
  settle()
  before <- reads
  before_callbacks <- length(callbacks)
  stale_tick()
  expect_identical(reads, before)
  expect_identical(length(callbacks), before_callbacks)
  expect_identical(before_callbacks, 3L)
  guard$dispose()
  callbacks[[length(callbacks)]]()
  expect_identical(reads, before)
})

test_that("cached tree and cgroup retain their own original sample times", {
  root <- tempfile("memory-timestamps-")
  pid <- 8181L
  proc <- file.path(root, pid)
  cgroup <- file.path(root, "cgroup")
  dir.create(proc, recursive = TRUE)
  dir.create(cgroup)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("VmRSS: 2048 kB", file.path(proc, "status"))
  writeLines(c("Rss: 2048 kB", "Pss: 1536 kB"), file.path(proc, "smaps_rollup"))
  writeLines("4096", file.path(cgroup, "memory.current"))
  writeLines("8192", file.path(cgroup, "memory.max"))
  writeLines(c("anon 1024", "file 3072", "inactive_file 2048"),
             file.path(cgroup, "memory.stat"))
  writeLines("some avg10=1.25 total=10", file.path(cgroup, "memory.pressure"))
  clock <- as.POSIXct("2026-09-18 09:00:00", tz = "UTC")
  sampler <- .new_linux_memory_guard_sampler(
    pid = pid, proc_root = root, cgroup_root = cgroup,
    cgroup_every = 3L, pss_trigger_bytes = 1, now = function() clock
  )
  first <- sampler()
  writeLines(c("anon 2048", "file 2048", "inactive_file 1024"),
             file.path(cgroup, "memory.stat"))
  writeLines("some avg10=2.50 total=20", file.path(cgroup, "memory.pressure"))
  clock <- clock + 5
  second <- sampler()
  clock <- clock + 5
  third <- sampler()
  expect_equal(as.numeric(second$captured_at - first$captured_at), 5)
  expect_identical(second$tree_captured_at, first$captured_at)
  expect_identical(second$cgroup_captured_at, first$captured_at)
  expect_identical(second$cgroup_stat, first$cgroup_stat)
  expect_identical(second$cgroup_pressure, first$cgroup_pressure)
  expect_identical(second$cgroup_stat$inactive_file, 2048)
  expect_identical(second$cgroup_pressure$some, 1.25)
  expect_identical(third$tree_captured_at, third$captured_at)
  expect_identical(third$cgroup_captured_at, third$captured_at)
  expect_identical(third$cgroup_stat$inactive_file, 1024)
  expect_identical(third$cgroup_pressure$some, 2.5)
})
