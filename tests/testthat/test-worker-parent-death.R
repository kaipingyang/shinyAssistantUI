parent_death_wait_until <- function(predicate, timeout = 5) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(predicate())) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.02)
  }
}
test_that("native parent-death guard kills worker grandchild tree and freezes destination", {
  skip_if_not(.Platform$OS.type == "unix" && dir.exists("/proc"))
  skip_if_not_installed("callr")
  skip_if(length(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())) > 0L,
          "parent-death fixture requires an isolated process")
  skip_if_not(identical(shinyAssistantUI:::.worker_supervision_capability()$category, "ok"))
  expect_true(shinyAssistantUI:::.native_set_subreaper())
  marker <- tempfile("parent-death-marker-", fileext = ".json")
  destination <- tempfile("parent-death-late-publish-")
  unlink(c(marker, destination), force = TRUE)
  before <- shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())
  owner <- callr::r_bg(
    function(marker, destination) {
      suppressPackageStartupMessages(library(shinyAssistantUI))
      parent_pid <- Sys.getpid()
      parent_start <- shinyAssistantUI:::.native_process_start_token(parent_pid)
      worker <- callr::r_bg(
        function(marker, destination, parent_pid, parent_start) {
          suppressPackageStartupMessages(library(shinyAssistantUI))
          if (!shinyAssistantUI:::.native_parent_guard_bootstrap(parent_pid, parent_start))
            quit(status = 91L)
          system2("sleep", "60", wait = FALSE, stdout = FALSE, stderr = FALSE)
          Sys.sleep(0.1)
          descendants <- shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())
          jsonlite::write_json(
            list(worker = Sys.getpid(), descendants = as.list(descendants)),
            marker, auto_unbox = TRUE
          )
          Sys.sleep(3)
          writeLines("LATE", destination)
          Sys.sleep(60)
        },
        args = list(marker = marker, destination = destination,
                    parent_pid = parent_pid, parent_start = parent_start),
        supervise = TRUE, stdout = "/dev/null", stderr = "/dev/null"
      )
      repeat Sys.sleep(1)
    },
    args = list(marker = marker, destination = destination),
    supervise = TRUE, stdout = "/dev/null", stderr = "/dev/null"
  )
  owned <- shinyAssistantUI:::.capture_owned_processes(before)
  on.exit({
    if (isTRUE(tryCatch(owner$is_alive(), error = function(error) FALSE)))
      try(owner$kill(), silent = TRUE)
    shinyAssistantUI:::.reap_owned_processes(owned)
    shinyAssistantUI:::.release_package_callr_supervisor()
    shinyAssistantUI:::.native_reap_children(1000L)
    unlink(c(marker, destination), force = TRUE)
  }, add = TRUE)
  expect_true(parent_death_wait_until(function() file.exists(marker), timeout = 5))
  process_ids <- jsonlite::read_json(marker, simplifyVector = TRUE)
  pids <- unique(as.integer(c(process_ids$worker, unlist(process_ids$descendants))))
  pids <- pids[!is.na(pids) & pids > 0L]
  expect_gte(length(pids), 2L)
  expect_true(tools::pskill(owner$get_pid(), signal = 9L))
  not_running <- function(pid) {
    status <- file.path("/proc", pid, "status")
    if (!file.exists(status)) return(TRUE)
    state <- grep("^State:", readLines(status, warn = FALSE), value = TRUE)
    length(state) == 1L && grepl("State:[[:space:]]+Z", state)
  }
  expect_true(parent_death_wait_until(function() all(vapply(pids, not_running, logical(1))), timeout = 5))
  first <- c(exists = file.exists(destination), size = if (file.exists(destination)) file.info(destination)$size else 0)
  Sys.sleep(1)
  second <- c(exists = file.exists(destination), size = if (file.exists(destination)) file.info(destination)$size else 0)
  expect_identical(second, first)
  expect_false(file.exists(destination))
  shinyAssistantUI:::.reap_owned_processes(owned)
  shinyAssistantUI:::.release_package_callr_supervisor()
  shinyAssistantUI:::.native_reap_children(2000L)
  expect_identical(length(shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())), 0L)
})
