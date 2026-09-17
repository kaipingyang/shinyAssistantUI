suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- httpuv::randomPort()
source("tests/verify/owned_process_cleanup.R", local = TRUE)
logs <- c("/tmp/aui-memory-plateau.out", "/tmp/aui-memory-plateau.err")
unlink(logs)
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-48s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project, port) {
  setwd(project)
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/memory_plateau_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
cleanup <- make_verification_cleanup(
  browser_session = function() if (exists("browser", inherits = FALSE)) browser else NULL,
  app_process = function() app,
  paths = logs
)
on.exit(cleanup(), add = TRUE)
for (i in seq_len(100L)) {
  if (!app$is_alive()) break
  if (file.exists(logs[[2L]]) && any(grepl(
    "Listening on", readLines(logs[[2L]], warn = FALSE)
  ))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) stop("Memory plateau app failed to boot")

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox",
  "--disable-gpu", "--disable-breakpad", "--disable-crash-reporter",
  "--no-crash-upload", "--js-flags=--expose-gc"
)))
browser <- ChromoteSession$new()
errors <- character()
browser$Runtime$enable()
browser$HeapProfiler$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) errors <<- c(errors, "console-error")
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  errors <<- c(errors, message$exceptionDetails$text %||% "exception")
})
value <- function(script) {
  response <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
  response$result$value
}
wait_for <- function(script, timeout = 12, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    result <- tryCatch(value(script), error = function(error) FALSE)
    if (isTRUE(result)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
read_count <- function() {
  text <- value("document.getElementById('memory-probe')?.textContent||''") %||% ""
  as.integer(sub("^.*reads=([0-9]+).*$", "\\1", text))
}
click_thread <- function(index) {
  title <- sprintf("Memory Thread %02d", index)
  encoded_title <- as.character(toJSON(title, auto_unbox = TRUE))
  locate <- sprintf(
    "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.innerText||'').includes(%s))",
    encoded_title
  )
  if (!wait_for(locate, 12)) return(FALSE)
  js <- sprintf(
    "(()=>{const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>(e.innerText||'').includes(%s));const b=e?.querySelector('[data-slot=aui_thread-list-item-trigger]')||e;b?.click();return !!b})()",
    encoded_title
  )
  isTRUE(value(js))
}
select_traversal <- function(thread_index, marker_turn) {
  marker <- sprintf("MEMORY_%02d_ASSISTANT_%03d", thread_index, marker_turn)
  encoded_marker <- as.character(toJSON(marker, auto_unbox = TRUE))
  click_thread(thread_index) && wait_for(sprintf(
    "document.body.innerText.includes(%s) && document.querySelectorAll('[data-role=user],[data-role=assistant]').length===240 && (()=>{for(const k of Object.keys(localStorage)){if(!k.includes(':msgs:'))continue;let xs=[];try{xs=JSON.parse(localStorage.getItem(k)||'[]')}catch{};if(JSON.stringify(xs).includes(%s))return xs.length===240}return false})()",
    encoded_marker, encoded_marker
  ), timeout = 30)
}
rss_bytes <- function(pid) {
  status <- readLines(file.path("/proc", pid, "status"), warn = FALSE)
  line <- grep("^VmRSS:", status, value = TRUE)
  if (!length(line)) return(NA_real_)
  as.numeric(sub("^VmRSS:[[:space:]]*([0-9]+).*$", "\\1", line[[1L]])) * 1024
}
samples <- list()
sample_memory <- function(phase, index) {
  value("Shiny.setInputValue('force_gc',Date.now(),{priority:'event'});globalThis.gc?.();true")
  try(browser$HeapProfiler$collectGarbage(), silent = TRUE)
  Sys.sleep(2)
  value("globalThis.gc?.();true")
  try(browser$HeapProfiler$collectGarbage(), silent = TRUE)
  heap <- browser$Runtime$getHeapUsage()
  storage <- value("(()=>{const keys=Object.keys(localStorage).filter(k=>k.includes(':msgs:'));return JSON.stringify({keys:keys.length,bytes:keys.reduce((n,k)=>n+(localStorage.getItem(k)||'').length,0)})})()")
  storage <- fromJSON(storage)
  sample <- list(
    phase = phase, index = index,
    app_rss = rss_bytes(app$get_pid()),
    js_heap = as.numeric(heap$usedSize),
    dom_messages = as.integer(value(
      "document.querySelectorAll('[data-role=user],[data-role=assistant]').length"
    )),
    storage_windows = as.integer(storage$keys),
    storage_bytes = as.numeric(storage$bytes),
    page_reads = read_count()
  )
  samples[[length(samples) + 1L]] <<- sample
  cat("MEMORY_SAMPLE ", as.character(toJSON(sample, auto_unbox = TRUE)), "\n", sep = "")
  sample
}

navigation_seq <- 0L
navigate <- function() {
  navigation_seq <<- navigation_seq + 1L
  if (navigation_seq == 1L) {
    browser$Page$navigate(sprintf("http://127.0.0.1:%d/?verification=memory", port))
    origin_condition <- "performance.timeOrigin>0"
  } else {
    previous_origin <- value("performance.timeOrigin")
    browser$Page$reload(ignoreCache = TRUE)
    origin_condition <- sprintf(
      "performance.timeOrigin!==%s",
      format(previous_origin, scientific = FALSE, digits = 17L, trim = TRUE)
    )
  }
  wait_for(sprintf(
    "%s && !!document.querySelector('.aui-root') && window.Shiny?.shinyapp?.$socket?.readyState===1 && (document.getElementById('memory-probe')?.textContent||'').includes('threads=20 total=10000')",
    origin_condition
  ), 20)
}
check("installed 10k-message app mounts", navigate())
check("twenty-thread fixture contract is published", isTRUE(value(
  "(document.getElementById('memory-probe')?.textContent||'').includes('threads=20 total=10000')"
)))
check("warm tail traversal", select_traversal(1L, 250L))
check("warm old-page traversal", select_traversal(2L, 120L))
check("warm server traversals completed", wait_for(
  "Number((document.getElementById('memory-probe')?.textContent||'').match(/reads=(\\d+)/)?.[1]||0)>=2",
  30
))

cycle_samples <- vector("list", 10L)
for (cycle in seq_len(10L)) {
  ok_a <- select_traversal(1L, 250L)
  ok_b <- select_traversal(2L, 120L)
  check(sprintf("tail-old traversal cycle %d", cycle), ok_a && ok_b)
  cycle_samples[[cycle]] <- sample_memory("cycle", cycle)
}

reconnect_samples <- vector("list", 10L)
for (index in seq_len(10L)) {
  ok <- navigate() && select_traversal(2L, 120L) && select_traversal(1L, 250L) && wait_for(
    "Number((document.getElementById('memory-probe')?.textContent||'').match(/reads=(\\d+)/)?.[1]||0)>=2",
    30
  )
  check(sprintf("browser reconnect %d", index), ok)
  reconnect_samples[[index]] <- sample_memory("reconnect", index)
}

cycle_rss <- vapply(cycle_samples, `[[`, numeric(1), "app_rss")
cycle_heap <- vapply(cycle_samples, `[[`, numeric(1), "js_heap")
reconnect_rss <- vapply(reconnect_samples, `[[`, numeric(1), "app_rss")
reconnect_heap <- vapply(reconnect_samples, `[[`, numeric(1), "js_heap")
not_positive_monotonic <- function(values) !all(diff(tail(values, 3L)) > 0)
check("cycle app RSS reaches plateau", not_positive_monotonic(cycle_rss),
      paste(tail(cycle_rss, 3L), collapse = ","))
check("cycle JS heap reaches plateau", not_positive_monotonic(cycle_heap),
      paste(tail(cycle_heap, 3L), collapse = ","))
check("reconnect app RSS reaches plateau", not_positive_monotonic(reconnect_rss),
      paste(tail(reconnect_rss, 3L), collapse = ","))
check("reconnect JS heap reaches plateau", not_positive_monotonic(reconnect_heap),
      paste(tail(reconnect_heap, 3L), collapse = ","))
check("retained browser message window remains bounded",
      max(vapply(samples, `[[`, numeric(1), "dom_messages")) <= 240L)
check("inactive persisted thread windows remain globally bounded",
      max(vapply(samples, `[[`, numeric(1), "storage_windows")) <= 8L)
check("persisted hot-message bytes remain within 8 MiB budget",
      max(vapply(samples, `[[`, numeric(1), "storage_bytes")) <= 8 * 1024^2)
check("no browser console errors or exceptions", length(errors) == 0L,
      paste(unique(errors), collapse = " | "))
cat("MEMORY_SAMPLES_JSON=", as.character(toJSON(samples, auto_unbox = TRUE)), "\n", sep = "")

cleanup()
if (length(failures)) stop("Memory plateau verification failed: ", paste(failures, collapse = ", "))
cat("MEMORY_PLATEAU_CHROMIUM_DONE\n")
