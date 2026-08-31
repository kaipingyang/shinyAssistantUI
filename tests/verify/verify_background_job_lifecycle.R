#!/usr/bin/env Rscript
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
site_library <- "/posit_share/site_library_u/4.4.3"
.libPaths(c(home_library, site_library, .libPaths()))
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(shinyAssistantUI)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
failures <- character()
check <- function(label, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-62s %s\n", if (ok) "PASS" else "FAIL", label, detail))
  if (!ok) failures <<- c(failures, label)
  invisible(ok)
}

installed <- normalizePath(find.package("shinyAssistantUI"), winslash = "/")
check("driver uses Home-installed shinyAssistantUI", startsWith(installed, home_library), installed)

tmp <- tempfile("bg-lifecycle-verify-")
dir.create(tmp, recursive = TRUE)
old_home <- Sys.getenv("HOME")
Sys.setenv(HOME = file.path(tmp, "home"))
dir.create(Sys.getenv("HOME"), recursive = TRUE)
chat_project <- file.path(tmp, "chat-project")
workspace_project <- file.path(tmp, "workspace-project")
dir.create(chat_project); dir.create(workspace_project)

children <- new.env(parent = emptyenv())
registry <- new.env(parent = emptyenv())
launch_count <- 0L
port_count <- 0L
shown <- character()
browsers <- list()
console_was_active <- isTRUE(shinyAssistantUI:::.claude_console_state$active)

cleanup <- function() {
  for (b in browsers) {
    try(b$close(), silent = TRUE)
    try(b$parent$get_browser()$get_process()$kill(), silent = TRUE)
  }
  for (id in ls(children, all.names = TRUE)) {
    item <- get(id, envir = children, inherits = FALSE)
    if (isTRUE(tryCatch(item$process$is_alive(), error = function(e) FALSE))) {
      try(item$process$kill(), silent = TRUE)
    }
    try(item$process$wait(timeout = 3000), silent = TRUE)
  }
  if (!console_was_active) try(shinyAssistantUI:::.addin_stop_r_console_server(), silent = TRUE)
  Sys.setenv(HOME = old_home)
  unlink(tmp, recursive = TRUE, force = TRUE)
}
on.exit(cleanup(), add = TRUE)

console_url <- shinyAssistantUI:::.addin_ensure_r_console_server(echo = FALSE)
check("one package-owned run_r endpoint starts", is.character(console_url) && nzchar(console_url), console_url %||% "NULL")
check("ensure returns the same run_r endpoint",
      identical(shinyAssistantUI:::.addin_ensure_r_console_server(echo = FALSE), console_url))

job_run <- function(path, name, workingDir) {
  launch_count <<- launch_count + 1L
  id <- sprintf("VERIFY-JOB-%d", launch_count)
  stdout <- file.path(tmp, paste0(id, ".out"))
  stderr <- file.path(tmp, paste0(id, ".err"))
  proc <- callr::r_bg(
    function(script, working_dir, home_library, site_library, expected_package) {
      .libPaths(c(home_library, site_library, .Library.site, .Library))
      stopifnot(identical(
        normalizePath(find.package("shinyAssistantUI"), winslash = "/"),
        expected_package
      ))
      setwd(working_dir)
      source(script, local = globalenv())
    },
    args = list(
      script = path, working_dir = workingDir,
      home_library = home_library, site_library = site_library,
      expected_package = installed
    ),
    stdout = stdout, stderr = stderr, supervise = TRUE
  )
  assign(id, list(process = proc, stdout = stdout, stderr = stderr, name = name),
         envir = children)
  id
}
job_state <- function(id) {
  if (is.null(id) || !exists(id, envir = children, inherits = FALSE)) return(NA_character_)
  proc <- get(id, envir = children, inherits = FALSE)$process
  if (isTRUE(tryCatch(proc$is_alive(), error = function(e) FALSE))) return("running")
  status <- tryCatch(proc$get_exit_status(), error = function(e) NA_integer_)
  if (!is.na(status) && identical(as.integer(status), 0L)) "succeeded" else "failed"
}
port_factory <- function() {
  port_count <<- port_count + 1L
  httpuv::randomPort(min = 20000L, max = 60000L)
}
wait_ready <- function(host, port, nonce, mode, job_id, instance_probe, job_state) {
  shinyAssistantUI:::.claude_wait_for_instance(
    host, port, nonce, mode, job_id,
    instance_probe = instance_probe, job_state = job_state,
    timeout = 35, interval = 0.1
  )
}
run <- function(spec) shinyAssistantUI:::.run_claude_bg_job(
  spec,
  registry = registry,
  port_factory = port_factory,
  job_run = job_run,
  job_state = job_state,
  wait_ready = wait_ready,
  show_viewer = function(url) shown <<- c(shown, url)
)

chat_spec <- list(
  project = chat_project, options = NULL, permission_mode = "default",
  prewarm = FALSE, models = NULL, console_url = console_url,
  workspace = FALSE, workspace_projects = NULL, job_name = "Claude Code Chat"
)
workspace_spec <- list(
  project = workspace_project, options = NULL, permission_mode = "default",
  prewarm = FALSE, models = NULL, console_url = console_url,
  workspace = TRUE, workspace_projects = c(workspace_project, chat_project),
  job_name = "Claude Workspace"
)

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))

inspect_app <- function(record, expected_mode) {
  b <- ChromoteSession$new(width = 1100, height = 760)
  browsers[[length(browsers) + 1L]] <<- b
  console_errors <- character()
  runtime_errors <- character()
  network_errors <- character()
  frame_errors <- character()
  b$Runtime$enable(); b$Network$enable()
  b$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors <<- c(console_errors, "console")
  })
  b$Runtime$exceptionThrown(callback_ = function(event) runtime_errors <<- c(runtime_errors, "runtime"))
  b$Network$loadingFailed(callback_ = function(event) network_errors <<- c(network_errors, event$errorText %||% "failed"))
  b$Network$webSocketFrameError(callback_ = function(event) frame_errors <<- c(frame_errors, event$errorMessage %||% "frame"))
  value <- function(js) {
    result <- b$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait_for <- function(js, timeout = 25) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(js), error = function(e) FALSE))) return(TRUE)
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.1)
    }
  }
  b$Page$navigate(record$url)
  try(b$Page$loadEventFired(timeout_ = 20), silent = TRUE)
  mounted <- wait_for("!!document.querySelector('.aui-root') && window.Shiny?.shinyapp?.$socket?.readyState===1")
  nonce <- value("document.querySelector('meta[name=\"shinyassistant-bg-nonce\"]')?.content||''")
  mode <- value("document.querySelector('meta[name=\"shinyassistant-bg-mode\"]')?.content||''")
  metrics <- list(
    mounted = mounted,
    nonce = nonce,
    mode = mode,
    text = value("document.body?.innerText?.length||0"),
    shiny_errors = value("document.querySelectorAll('.shiny-output-error').length"),
    recalculating = value("document.querySelectorAll('.shiny-bound-output.recalculating').length"),
    socket = value("window.Shiny?.shinyapp?.$socket?.readyState ?? -1"),
    restart_button = value("/Restart Workspace|Restart Chat|lifecycle/i.test(document.body?.innerText||'')"),
    console = length(console_errors), runtime = length(runtime_errors),
    network = length(network_errors), frame = length(frame_errors)
  )
  check(paste(expected_mode, "exact nonce marker"), identical(metrics$nonce, record$nonce), metrics$nonce)
  check(paste(expected_mode, "exact mode marker"), identical(metrics$mode, expected_mode), metrics$mode)
  check(paste(expected_mode, "widget mounted and socket OPEN"), metrics$mounted && metrics$socket == 1L)
  check(paste(expected_mode, "non-empty DOM"), metrics$text > 0L, paste("chars", metrics$text))
  check(paste(expected_mode, "no Shiny errors/recalculating"), metrics$shiny_errors == 0L && metrics$recalculating == 0L)
  check(paste(expected_mode, "zero console/runtime/network/frame errors"),
        metrics$console + metrics$runtime + metrics$network + metrics$frame == 0L)
  check(paste(expected_mode, "no new restart/lifecycle control"), !metrics$restart_button)
  try(b$Page$navigate("about:blank"), silent = TRUE)
  try(b$close(), silent = TRUE)
  metrics
}

kill_owned <- function(id) {
  item <- get(id, envir = children, inherits = FALSE)
  if (item$process$is_alive()) item$process$kill()
  item$process$wait(timeout = 5000)
  deadline <- Sys.time() + 5
  while (item$process$is_alive() && Sys.time() < deadline) Sys.sleep(0.05)
  check(paste(id, "terminated by verifier"), !item$process$is_alive())
}

# C1 launch and healthy reuse.
c1 <- run(chat_spec)
check("C1 is a new Chat generation", !c1$reused && c1$mode == "chat" && c1$generation == 1L)
check("C1 exact HTTP marker is healthy",
      shinyAssistantUI:::.claude_bg_probe_instance("127.0.0.1", c1$port, c1$nonce, "chat"))
inspect_app(c1, "chat")
c1_reuse <- run(chat_spec)
check("identical Chat reuses C1", c1_reuse$reused && identical(c1_reuse$job_id, c1$job_id) &&
        identical(c1_reuse$port, c1$port) && identical(c1_reuse$nonce, c1$nonce))
check("Chat reuse creates no child/port", launch_count == 1L && port_count == 1L)

# W1 is isolated from C1 and healthy-reuses.
w1 <- run(workspace_spec)
check("W1 is a distinct Workspace generation", !w1$reused && w1$mode == "workspace" &&
        !identical(w1$job_id, c1$job_id) && !identical(w1$port, c1$port))
inspect_app(w1, "workspace")
w1_reuse <- run(workspace_spec)
check("identical Workspace reuses W1", w1_reuse$reused && identical(w1_reuse$job_id, w1$job_id))
check("Workspace reuse creates no child/port", launch_count == 2L && port_count == 2L)
check("C1 remains independently reusable", identical(run(chat_spec)$job_id, c1$job_id))

# Both materialized specs share the stable main-session run_r endpoint.
c1_spec <- readRDS(c1$spec_path)
w1_spec <- readRDS(w1$spec_path)
check("Chat and Workspace specs share stable run_r URL",
      identical(c1_spec$console_url, console_url) && identical(w1_spec$console_url, console_url))

# Two clients use the two materialized specs while the main process pumps later.
run_r_client <- function(url, variable, value) callr::r_bg(
  function(home_library, site_library, url, variable, value) {
    .libPaths(c(home_library, site_library, .Library.site, .Library))
    quoted <- encodeString(variable, quote = '"')
    code <- sprintf("assign(%s, %dL, envir=.GlobalEnv); get(%s, envir=.GlobalEnv)",
                    quoted, as.integer(value), quoted)
    shinyAssistantUI:::.addin_run_r_remote(url, code, timeout = 10000)
  },
  args = list(home_library = home_library, site_library = site_library,
              url = url, variable = variable, value = value),
  stdout = file.path(tmp, paste0(variable, ".out")),
  stderr = file.path(tmp, paste0(variable, ".err")), supervise = TRUE
)
rc1 <- run_r_client(c1_spec$console_url, "BG_CHAT_ROUNDTRIP", 11L)
rw1 <- run_r_client(w1_spec$console_url, "BG_WORKSPACE_ROUNDTRIP", 22L)
deadline <- Sys.time() + 15
while ((rc1$is_alive() || rw1$is_alive()) && Sys.time() < deadline) {
  later::run_now(0.05)
}
check("Chat run_r client completed", !rc1$is_alive())
check("Workspace run_r client completed", !rw1$is_alive())
rc1_result <- tryCatch(rc1$get_result(), error = function(e) NULL)
rw1_result <- tryCatch(rw1$get_result(), error = function(e) NULL)
check("both modes reach the live main R session",
      isTRUE(rc1_result$ok) && isTRUE(rw1_result$ok) &&
        identical(get("BG_CHAT_ROUNDTRIP", envir = globalenv()), 11L) &&
        identical(get("BG_WORKSPACE_ROUNDTRIP", envir = globalenv()), 22L))

# Kill only C1, recover C2, and prove W1 is unchanged.
kill_owned(c1$job_id)
c2 <- run(chat_spec)
check("dead C1 recovers as C2", !c2$reused && c2$generation == 2L &&
        !identical(c2$job_id, c1$job_id) && !identical(c2$port, c1$port) &&
        !identical(c2$nonce, c1$nonce))
inspect_app(c2, "chat")
check("W1 unchanged after Chat recovery", identical(run(workspace_spec)$job_id, w1$job_id))

# Kill only W1, recover W2, and prove C2 is unchanged.
kill_owned(w1$job_id)
w2 <- run(workspace_spec)
check("dead W1 recovers as W2", !w2$reused && w2$generation == 2L &&
        !identical(w2$job_id, w1$job_id) && !identical(w2$port, w1$port) &&
        !identical(w2$nonce, w1$nonce))
inspect_app(w2, "workspace")
check("C2 unchanged after Workspace recovery", identical(run(chat_spec)$job_id, c2$job_id))
check("exactly four generations launched", launch_count == 4L && port_count == 4L)
active_children <- sum(vapply(ls(children), function(id) {
  get(id, envir = children, inherits = FALSE)$process$is_alive()
}, logical(1)))
check("only recovered C2 and W2 remain active", active_children == 2L, paste("active", active_children))
check("every Viewer open used lifecycle URL", length(shown) >= 8L && all(startsWith(shown, "http://127.0.0.1:")))

if (length(failures)) stop("Background lifecycle verification failed: ", paste(failures, collapse = ", "), call. = FALSE)
cat("BACKGROUND_JOB_LIFECYCLE_VERIFY_DONE\n")
