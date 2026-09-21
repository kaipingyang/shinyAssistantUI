suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
expected_package <- file.path(home_lib, "shinyAssistantUI")
installed_package <- find.package(
  "shinyAssistantUI", lib.loc = home_lib, quiet = TRUE
)
if (!nzchar(installed_package) ||
    !identical(normalizePath(installed_package), normalizePath(expected_package))) {
  stop("HOME installed shinyAssistantUI not found at ", expected_package)
}
installed_version <- as.character(utils::packageVersion(
  "shinyAssistantUI", lib.loc = home_lib
))
cat("HOME_PACKAGE_PATH=", normalizePath(installed_package), "\n", sep = "")
cat("HOME_PACKAGE_VERSION=", installed_version, "\n", sep = "")

source(file.path(project, "tests", "verify", "owned_process_cleanup.R"))
run_id <- paste0(Sys.getpid(), "-", as.integer(Sys.time()))
paths <- file.path("/tmp", paste0("aui-memory-guard-", run_id, c(
  ".out", ".err", ".client-sentinel"
)))
stdout_path <- paths[[1L]]
stderr_path <- paths[[2L]]
sentinel_path <- paths[[3L]]
app_project <- file.path("/tmp", paste0("aui-memory-guard-project-", run_id))
dir.create(app_project, recursive = TRUE, showWarnings = FALSE)
unlink(paths)

browser <- NULL
app <- NULL
cleanup <- make_verification_cleanup(
  browser_session = function() browser,
  app_process = function() app,
  paths = c(paths, app_project)
)
on.exit(cleanup(), add = TRUE)

failures <- character()
check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf(
    "[%s] %-58s %s\n",
    if (passed) "PASS" else "FAIL", name, detail
  ))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}
read_log <- function(path) {
  if (!file.exists(path)) return(character())
  readLines(path, warn = FALSE)
}
wait_until <- function(predicate, timeout = 15, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(predicate(), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}

port <- httpuv::randomPort()
app <- callr::r_bg(
  function(home_lib, app_project, port, sentinel_path) {
    .libPaths(c(home_lib, .libPaths()))
    suppressPackageStartupMessages({
      library(shiny)
      library(shinyAssistantUI, lib.loc = home_lib)
    })
    cat("APP_PACKAGE_PATH=", normalizePath(find.package("shinyAssistantUI")), "\n", sep = "")
    cat("APP_PACKAGE_VERSION=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
    flush.console()

    high_rss <- list(
      available = TRUE,
      source = "browser-fixture-high-rss",
      pid = Sys.getpid(),
      captured_at = Sys.time(),
      rss_bytes = 4096,
      pss_bytes = NULL,
      tree_rss_bytes = 4096 + 2048,
      tree_process_count = 2L,
      private_dirty_bytes = NULL,
      anonymous_bytes = NULL,
      cgroup_current_bytes = 2 * 1024^3,
      cgroup_max_bytes = 10 * 1024^3,
      cgroup_events = list()
    )
    original_make_claude_handler <- get(
      "make_claude_handler", envir = asNamespace("shinyAssistantUI")
    )

    testthat::local_mocked_bindings(
      .read_linux_memory_snapshot = function(...) high_rss,
      .new_claude_client = function(options) {
        writeLines(
          paste("SDK client construction attempted", Sys.time()),
          sentinel_path
        )
        stop("SDK client must not be created by this verification")
      },
      make_claude_handler = function(...) {
        handler <- original_make_claude_handler(...)
        later::later(function() {
          observe_guard <- attr(handler, ".memory_guard_observe")
          if (!is.function(observe_guard)) {
            cat("GUARD_OBSERVER_MISSING\n")
            flush.console()
            return(invisible(NULL))
          }
          observe_guard()
          observed <- attr(handler, ".memory_guard_snapshot")()
          cat("GUARD_OBSERVED_STATE=", observed$state, "\n", sep = "")
          flush.console()
          later::later(function() {
            settled <- attr(handler, ".memory_guard_snapshot")()
            cat("GUARD_SETTLED_STATE=", settled$state, "\n", sep = "")
            cat("GUARD_SETTLED_IDLE=", identical(settled$state, "hard_idle"), "\n", sep = "")
            allows <- attr(handler, ".memory_guard_allows")
            cat("GUARD_FOREGROUND_ALLOWED=", is.function(allows) && allows("foreground"), "\n", sep = "")
            cat("GUARD_WARMUP_ALLOWED=", is.function(allows) && allows("warmup"), "\n", sep = "")
            flush.console()
          }, delay = 0.20)
          invisible(NULL)
        }, delay = 0.35)
        handler
      },
      .package = "shinyAssistantUI"
    )

    guard_config <- list(
      enabled = TRUE,
      soft_pss_bytes = 100,
      hard_pss_bytes = 200,
      soft_rss_bytes = 100,
      hard_rss_bytes = 200,
      consecutive_samples = 1L,
      hysteresis = 0.8,
      active_interval = 0.05,
      idle_interval = 0.05,
      settle_delay = 0.10
    )
    app <- shinyAssistantUI:::.claude_chat_app(
      project = app_project,
      prewarm = FALSE,
      memory_guard_config = guard_config
    )
    shiny::runApp(
      app,
      host = "127.0.0.1",
      port = port,
      launch.browser = FALSE
    )
  },
  args = list(
    home_lib = home_lib,
    app_project = app_project,
    port = port,
    sentinel_path = sentinel_path
  ),
  stdout = stdout_path,
  stderr = stderr_path,
  supervise = TRUE,
  env = c(R_LIBS_USER = home_lib, HOME = app_project)
)

listening <- wait_until(function() {
  if (!app$is_alive()) return(FALSE)
  any(grepl("Listening on", read_log(stderr_path), fixed = TRUE))
}, timeout = 20)
if (!listening) {
  cat("APP_STDOUT_TAIL_BEGIN\n", paste(tail(read_log(stdout_path), 40), collapse = "\n"),
      "\nAPP_STDOUT_TAIL_END\n", sep = "")
  cat("APP_STDERR_TAIL_BEGIN\n", paste(tail(read_log(stderr_path), 40), collapse = "\n"),
      "\nAPP_STDERR_TAIL_END\n", sep = "")
  stop("installed addin app failed to start")
}
check("callr app is alive", app$is_alive())
check(
  "app process loaded the HOME installed package",
  wait_until(function() any(grepl(
    paste0("APP_PACKAGE_PATH=", normalizePath(expected_package)),
    read_log(stdout_path), fixed = TRUE
  )), timeout = 5),
  normalizePath(expected_package)
)
check(
  "app process reports expected installed version",
  any(grepl(
    paste0("APP_PACKAGE_VERSION=", installed_version),
    read_log(stdout_path), fixed = TRUE
  )),
  installed_version
)

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 900, height = 760)
console_errors <- character()
runtime_exceptions <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (!identical(message$type, "error")) return(invisible(NULL))
  values <- vapply(message$args %||% list(), function(arg) {
    as.character(arg$value %||% arg$description %||% "<console error>")
  }, character(1))
  console_errors <<- c(console_errors, paste(values, collapse = " "))
  invisible(NULL)
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  runtime_exceptions <<- c(
    runtime_exceptions,
    as.character(detail$exception$description %||% detail$text %||% "<runtime exception>")
  )
  invisible(NULL)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) {
    stop(result$exceptionDetails$text %||% "JavaScript evaluation failed")
  }
  result$result$value
}
wait_js <- function(script, timeout = 15) {
  wait_until(function() isTRUE(value(script)), timeout = timeout)
}
click_selector <- function(selector) {
  point_json <- value(sprintf(
    paste0(
      "(function(){const e=document.querySelector(%s);if(!e)return null;",
      "const r=e.getBoundingClientRect();",
      "return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()"
    ),
    jsonlite::toJSON(selector, auto_unbox = TRUE)
  ))
  if (is.null(point_json)) return(FALSE)
  point <- jsonlite::fromJSON(point_json)
  browser$Input$dispatchMouseEvent(
    type = "mousePressed", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  browser$Input$dispatchMouseEvent(
    type = "mouseReleased", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  TRUE
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("assistant widget mounted", wait_js("!!document.querySelector('.aui-root')", 15))

settled <- wait_until(function() {
  any(grepl("GUARD_SETTLED_STATE=hard_idle", read_log(stdout_path), fixed = TRUE))
}, timeout = 10)
check(
  "idle hard pressure settled to sticky hard_idle",
  settled,
  paste(grep("GUARD_", read_log(stdout_path), value = TRUE), collapse = " | ")
)
check("Performance Orb expands for backend refresh", click_selector("button[aria-label='Performance diagnostics']"))
check("Performance Orb refresh control appears", wait_js(
  "!!document.querySelector(\"button[aria-label='Refresh backend memory']\")", 8
))
check("initial Orb opening reaches R as openId 1", wait_js(
  "((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible']?.openId === 1", 8
))
check("backend panel separates process from process tree", wait_js(
  paste0("(function(){const t=document.querySelector('[data-slot=aui_backend_memory]')?.innerText||'';",
         "return /RSS /.test(t)&&/Process tree /.test(t)&&/Session /.test(t);})()"), 8
))
check("first frame reports a process tree covering at least the R process", wait_js(
  paste0("(function(){const t=document.querySelector('[data-slot=aui_backend_memory]')?.innerText||'';",
         "const m=t.match(/Process tree ([^\\n]*)/);return !!m&&!/Unavailable/.test(m[1])&&/procs/.test(m[1]);})()"), 10
), paste("panel=", value(
  "(document.querySelector('[data-slot=aui_backend_memory]')?.innerText||'').replace(/\\n/g,' | ')"
)))
check("backend refresh uses a real pointer click", click_selector(
  "button[aria-label='Refresh backend memory']"
))
check("refresh advances exact memory opening to openId 2", wait_js(
  "(function(){const v=((window.Shiny&&Shiny.shinyapp&&Shiny.shinyapp.$inputValues)||{})['chat_input_memory_monitor_visible'];return v?.version===3&&v?.visible===true&&v?.openId===2&&v?.sample===null&&Object.keys(v).length===6;})()", 8
))
check("refreshed backend panel remains rendered", wait_js(
  "(document.querySelector('[data-slot=aui_backend_memory]')?.innerText||'').includes('Backend memory')", 8
))
check("Performance Orb collapses after refresh proof", click_selector(
  "button[aria-label='Performance diagnostics']"
))
check("no SDK client before submission", !file.exists(sentinel_path))

submit_composer <- function(text) {
  if (!click_selector(".aui-lexical-input[contenteditable='true']")) return(FALSE)
  Sys.sleep(0.25)
  browser$Input$insertText(text = text)
  Sys.sleep(0.15)
  press_enter()
  TRUE
}
guard_log <- read_log(stdout_path)
check("hard process pressure allows explicit foreground with cgroup headroom",
      any(grepl("GUARD_FOREGROUND_ALLOWED=TRUE", guard_log, fixed = TRUE)),
      paste(grep("GUARD_", guard_log, value = TRUE), collapse = " | "))
check("hard process pressure pauses background warmup",
      any(grepl("GUARD_WARMUP_ALLOWED=FALSE", guard_log, fixed = TRUE)))

message_text <- "memory guard browser foreground probe"
check(
  "composer focused through real CDP pointer input",
  submit_composer(message_text)
)
check(
  "cgroup-safe foreground reaches SDK construction instead of guard rejection",
  wait_until(function() file.exists(sentinel_path), timeout = 15)
)
check(
  "submitted foreground message is represented in DOM",
  isTRUE(value(sprintf(
    "(document.querySelector('.aui-root')?.innerText||'').includes(%s)",
    jsonlite::toJSON(message_text, auto_unbox = TRUE)
  )))
)
check("no recycle guidance is shown while cgroup has headroom", isTRUE(value(
  "!(document.querySelector('.aui-root')?.innerText||'').includes('Close and reopen the addin')"
)))

check("widget remains mounted after allowed foreground attempt", isTRUE(value(
  "!!document.querySelector('.aui-root') && !!document.querySelector(\".aui-lexical-input[contenteditable='true']\")"
)))
check("callr app remains alive after allowed attempt", app$is_alive())

# Record compact DOM/data-* truth rather than relying on a screenshot.
dom_evidence <- value(paste0(
  "(function(){const root=document.querySelector('.aui-root');",
  "const all=root?Array.from(root.querySelectorAll('*')):[];",
  "const hit=all.filter(e=>/close and reopen/i.test(e.textContent||'')&&",
  "/Background Job R/i.test(e.textContent||'')).pop();",
  "const attrs=e=>e?Object.fromEntries(Array.from(e.attributes)",
  ".filter(a=>a.name.startsWith('data-')).map(a=>[a.name,a.value])):{};",
  "return JSON.stringify({mounted:!!root,rootData:attrs(root),",
  "composerData:attrs(root?.querySelector(\".aui-lexical-input[contenteditable='true']\")),",
  "guidanceTag:hit?.tagName||null,guidanceData:attrs(hit),",
  "guidanceText:(hit?.textContent||'').trim().slice(0,500),",
  "rootText:(root?.innerText||'').trim().slice(-1200)});})()"
))
cat("DOM_EVIDENCE=", dom_evidence, "\n", sep = "")
cat(
  "GUARD_LOG_EVIDENCE=",
  paste(grep("^(APP_PACKAGE|GUARD_)", read_log(stdout_path), value = TRUE), collapse = " | "),
  "\n", sep = ""
)

# Allow asynchronous browser callbacks to drain before asserting error counts.
Sys.sleep(0.5)
check(
  "zero browser console errors",
  length(console_errors) == 0L,
  if (length(console_errors)) paste(console_errors, collapse = " | ") else "count=0"
)
check(
  "zero Runtime.exceptionThrown events",
  length(runtime_exceptions) == 0L,
  if (length(runtime_exceptions)) paste(runtime_exceptions, collapse = " | ") else "count=0"
)

cat("APP_STDOUT_TAIL_BEGIN\n", paste(tail(read_log(stdout_path), 30), collapse = "\n"),
    "\nAPP_STDOUT_TAIL_END\n", sep = "")
cat("APP_STDERR_TAIL_BEGIN\n", paste(tail(read_log(stderr_path), 30), collapse = "\n"),
    "\nAPP_STDERR_TAIL_END\n", sep = "")
cleanup()

if (length(failures)) {
  stop("verification failed: ", paste(failures, collapse = ", "))
}
cat("MEMORY_GUARD_BROWSER_VERIFY_DONE\n")
