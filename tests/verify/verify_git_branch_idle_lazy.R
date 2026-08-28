.libPaths(c(
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4",
  "/mnt/usrfiles/bgcrh/build/zzz_tools/r_wg/rlibrary/R4.4.0",
  .libPaths()
))
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- normalizePath("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI", winslash = "/")
port <- httpuv::randomPort()
stdout_log <- tempfile("branch-idle-browser-", fileext = ".out")
stderr_log <- tempfile("branch-idle-browser-", fileext = ".err")
app <- callr::r_bg(
  function(project, port) {
    .libPaths(c(
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4",
  "/mnt/usrfiles/bgcrh/build/zzz_tools/r_wg/rlibrary/R4.4.0",
  .libPaths()
))
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp(
      "tests/verify/git_branch_idle_lazy_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  },
  args = list(project = project, port = port),
  stdout = stdout_log, stderr = stderr_log
)
on.exit({
  try(app$kill(), silent = TRUE)
  unlink(c(stdout_log, stderr_log))
}, add = TRUE)

for (i in seq_len(120L)) {
  if (!app$is_alive()) {
    cat("App stderr:\n", paste(readLines(stderr_log, warn = FALSE), collapse = "\n"), "\n")
    stop("Browser fixture failed to start")
  }
  logs <- paste(
    tryCatch(readLines(stdout_log, warn = FALSE), error = function(e) character()),
    tryCatch(readLines(stderr_log, warn = FALSE), error = function(e) character()),
    collapse = "\n"
  )
  ready <- grepl("Listening on http://127.0.0.1:", logs, fixed = TRUE)
  if (ready) break
  Sys.sleep(0.1)
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- chromote::ChromoteSession$new()
on.exit(try(browser$close(), silent = TRUE), add = TRUE)

console_errors <- character()
runtime_errors <- character()
network_errors <- character()
browser$Runtime$enable()
browser$Network$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    text <- paste(vapply(message$args, function(arg) {
      as.character(arg$value %||% arg$description %||% "")
    }, character(1)), collapse = " ")
    console_errors <<- c(console_errors, text)
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  runtime_errors <<- c(runtime_errors, as.character(
    detail$exception$description %||% detail$text %||% "runtime exception"
  ))
})
browser$Network$loadingFailed(callback_ = function(message) {
  if (!identical(message$canceled, TRUE)) {
    network_errors <<- c(network_errors, as.character(message$errorText %||% "loading failed"))
  }
})
browser$Network$responseReceived(callback_ = function(message) {
  status <- as.numeric(message$response$status %||% 0)
  if (is.finite(status) && status >= 400) {
    network_errors <<- c(network_errors, paste(status, message$response$url %||% ""))
  }
})

evaluate <- function(script) {
  response <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
  response$result$value
}
wait_for <- function(script, seconds = 12) {
  deadline <- Sys.time() + seconds
  repeat {
    value <- tryCatch(evaluate(script), error = function(e) FALSE)
    if (isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.1)
  }
}
check <- function(label, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %s%s\n", if (passed) "PASS" else "FAIL", label,
              if (nzchar(detail)) paste0(" — ", detail) else ""))
  if (!passed) {
    body <- tryCatch(evaluate("document.body.innerText"), error = function(e) "<unavailable>")
    location <- tryCatch(evaluate("location.href"), error = function(e) "<unavailable>")
    html <- tryCatch(evaluate("document.documentElement.outerHTML"), error = function(e) "<unavailable>")
    cat("Location:\n", location, "\nDOM:\n", body, "\nHTML:\n", substr(html, 1, 3000), "\n", sep = "")
    if (length(console_errors)) cat("Console:\n", paste(console_errors, collapse = "\n"), "\n")
    if (length(runtime_errors)) cat("Runtime:\n", paste(runtime_errors, collapse = "\n"), "\n")
    if (length(network_errors)) cat("Network:\n", paste(network_errors, collapse = "\n"), "\n")
    if (file.exists(stderr_log)) cat("App stderr:\n", paste(readLines(stderr_log, warn = FALSE), collapse = "\n"), "\n")
    stop(label, call. = FALSE)
  }
}
click_thread <- function(title) {
  encoded <- jsonlite::toJSON(title, auto_unbox = TRUE)
  point <- evaluate(sprintf(
    "(function(){const title=%s;const e=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>(x.textContent||'').includes(title));if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()",
    encoded
  ))
  if (is.null(point)) return(FALSE)
  xy <- jsonlite::fromJSON(point)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = xy$x, y = xy$y,
                                   button = "left", clickCount = 1)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = xy$x, y = xy$y,
                                   button = "left", clickCount = 1)
  TRUE
}

url <- sprintf("http://127.0.0.1:%d/", port)
browser$Page$navigate(url)
browser$Page$loadEventFired()
check("widget and three history sessions loaded", wait_for(
  "document.querySelectorAll('[data-slot=aui_thread-list-item]').length >= 3 && !!document.querySelector('[data-slot=aui_composer_meta_footer]')",
  15
))
expected_branch <- evaluate("document.getElementById('expected_branch').textContent.trim()")
check("Git branch appears below composer", nzchar(expected_branch) && isTRUE(evaluate(sprintf(
  "document.querySelector('[data-slot=aui_git_branch]')?.textContent.trim() === %s",
  jsonlite::toJSON(expected_branch, auto_unbox = TRUE)
))), expected_branch)

for (index in seq_len(3L)) {
  check(paste("clicked history", index), click_thread(paste("History", index)))
  check(paste("history", index, "loaded from transcript"), wait_for(sprintf(
    "document.body.innerText.includes('Loaded history-%d') && document.getElementById('history_count').textContent.trim()==='%d'",
    index, index
  )))
}
check("history browsing starts zero backend clients", isTRUE(evaluate(
  "document.getElementById('client_count').textContent.trim()==='0'"
)))

check("clear current project branch control clicked", isTRUE(evaluate(
  "(function(){const b=document.getElementById('clear_branch');if(!b)return false;b.click();return true})()"
)))
check("non-Git/null branch removes footer element", wait_for(
  "!document.querySelector('[data-slot=aui_git_branch]')"
))
check("stale project branch control clicked", isTRUE(evaluate(
  "(function(){const b=document.getElementById('stale_branch');if(!b)return false;b.click();return true})()"
)))
Sys.sleep(0.4)
check("stale project branch is ignored", isTRUE(evaluate(
  "!document.querySelector('[data-slot=aui_git_branch]') && !document.body.innerText.includes('stale/branch')"
)))

check("composer focused", isTRUE(evaluate(
  "(function(){const t=document.querySelector('[contenteditable=\"true\"]')||document.querySelector('textarea');if(!t)return false;t.focus();return true})()"
)))
browser$Input$insertText(text = "start browser background task")
browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                               windowsVirtualKeyCode = 13L)
browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                               windowsVirtualKeyCode = 13L)
check("first send lazily creates exactly one backend client", wait_for(
  "document.getElementById('client_count').textContent.trim()==='1'"
))
check("foreground-owned background approval renders one card", wait_for(
  "document.querySelectorAll('.aui-shiny-approval').length===1 && [...document.querySelectorAll('.aui-shiny-approval button')].some(b=>(b.textContent||'').trim()==='Approve'&&!b.disabled)",
  15
))
initial_cards <- as.integer(evaluate("document.querySelectorAll('.aui-shiny-approval').length"))
check("associated approval card is in viewport", isTRUE(evaluate(
  "(function(){const e=document.querySelector('.aui-shiny-approval');if(!e)return false;const r=e.getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=window.innerHeight+2})()"
)))
check("Approve clicked", isTRUE(evaluate(
  "(function(){const b=[...document.querySelectorAll('.aui-shiny-approval button')].find(x=>(x.textContent||'').trim()==='Approve'&&!x.disabled);if(!b)return false;b.click();return true})()"
)))
check("associated approval reaches backend once", wait_for(
  "document.getElementById('approval_count').textContent.trim()==='1'"
))
notification <- "A background task requested approval and was stopped because no interactive run was available."
check("detached approval is denied and interrupted", wait_for(
  "Number(document.getElementById('denial_count').textContent.trim())===1 && Number(document.getElementById('interrupt_count').textContent.trim())>=1",
  15
))
check("detached transcript reply appears without another send", wait_for(
  "document.body.innerText.includes('Transcript reply published before detached approval stopped.')"
))
check("detached English notification appears", wait_for(sprintf(
  "document.body.innerText.includes(%s)", jsonlite::toJSON(notification, auto_unbox = TRUE)
)))
check("detached request creates no additional approval card", isTRUE(evaluate(sprintf(
  "document.querySelectorAll('.aui-shiny-approval').length<=%d && ![...document.querySelectorAll('.aui-shiny-approval button')].some(b=>(b.textContent||'').trim()==='Approve'&&!b.disabled)",
  initial_cards
))))
check("run completion refreshes Git branch", wait_for(sprintf(
  "document.querySelector('[data-slot=aui_git_branch]')?.textContent.trim()===%s",
  jsonlite::toJSON(expected_branch, auto_unbox = TRUE)
)))

Sys.sleep(0.5)
check("zero browser console errors", length(console_errors) == 0L,
      paste(unique(console_errors), collapse = " | "))
check("zero browser runtime exceptions", length(runtime_errors) == 0L,
      paste(unique(runtime_errors), collapse = " | "))
check("zero browser network errors", length(network_errors) == 0L,
      paste(unique(network_errors), collapse = " | "))

browser$close()
app$kill()
cat("GIT_BRANCH_IDLE_LAZY_BROWSER_DONE\n")
