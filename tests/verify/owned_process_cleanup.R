# Idempotent cleanup for Chromium verification scripts executed by the bounded runner.
# The runner gives each script a dedicated process-supervisor.py parent, so adopted
# descendants under that parent are owned by this one verification batch.

.cleanup_runner_owned_descendants <- function() {
  stat_tail <- sub("^.*\\) ", "", readLines("/proc/self/stat", n = 1L, warn = FALSE))
  parent_pid <- strsplit(stat_tail, " ", fixed = TRUE)[[1L]][[2L]]
  parent_cmd_path <- file.path("/proc", parent_pid, "cmdline")
  if (!file.exists(parent_cmd_path)) return(invisible(NULL))
  parent_raw <- readBin(parent_cmd_path, what = "raw", n = 4096L)
  parent_raw[parent_raw == as.raw(0L)] <- charToRaw(" ")
  if (!grepl("process-supervisor.py", rawToChar(parent_raw), fixed = TRUE)) {
    return(invisible(NULL))
  }

  proc_children <- function(pid) {
    path <- file.path("/proc", pid, "task", pid, "children")
    if (!file.exists(path)) return(integer())
    scan(path, what = integer(), quiet = TRUE)
  }
  owned <- function() {
    seen <- integer()
    frontier <- proc_children(Sys.getpid())
    while (length(frontier)) {
      frontier <- setdiff(unique(frontier), seen)
      if (!length(frontier)) break
      seen <- c(seen, frontier)
      frontier <- unique(unlist(lapply(frontier, proc_children), use.names = FALSE))
    }
    adopted <- setdiff(proc_children(parent_pid), Sys.getpid())
    unique(c(seen, adopted))
  }

  targets <- owned()
  for (pid in targets) try(tools::pskill(pid, 15L), silent = TRUE)
  deadline <- Sys.time() + 1
  repeat {
    survivors <- intersect(targets, owned())
    if (!length(survivors) || Sys.time() >= deadline) break
    Sys.sleep(0.05)
  }
  for (pid in survivors) try(tools::pskill(pid, 9L), silent = TRUE)
  deadline <- Sys.time() + 1
  while (length(intersect(survivors, owned())) && Sys.time() < deadline) {
    Sys.sleep(0.05)
  }
  invisible(NULL)
}

make_verification_cleanup <- function(browser_session, app_process, paths = character()) {
  cleaned <- FALSE
  function() {
    if (isTRUE(cleaned)) return(invisible(NULL))
    cleaned <<- TRUE

    browser <- tryCatch(browser_session(), error = function(error) NULL)
    parent <- if (is.null(browser)) NULL else tryCatch(browser$parent, error = function(error) NULL)
    chrome_browser <- if (is.null(parent)) NULL else tryCatch(
      parent$get_browser(), error = function(error) NULL
    )
    chrome_process <- if (is.null(chrome_browser)) NULL else tryCatch(
      chrome_browser$get_process(), error = function(error) NULL
    )

    if (!is.null(browser)) try(browser$close(), silent = TRUE)
    if (!is.null(chrome_browser)) try(chrome_browser$close(), silent = TRUE)
    if (!is.null(parent)) try(parent$close(), silent = TRUE)
    if (!is.null(chrome_process)) {
      try(if (chrome_process$is_alive()) chrome_process$kill_tree(), silent = TRUE)
      try(chrome_process$wait(timeout = 5000L), silent = TRUE)
    }

    app <- tryCatch(app_process(), error = function(error) NULL)
    if (!is.null(app)) {
      try(if (app$is_alive()) app$kill_tree(), silent = TRUE)
      try(app$wait(timeout = 5000L), silent = TRUE)
    }

    invisible(gc())
    .cleanup_runner_owned_descendants()
    if (length(paths)) unlink(paths)
    invisible(NULL)
  }
}
