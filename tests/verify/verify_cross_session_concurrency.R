#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- 9187L
LOG <- "/tmp/plan67-browser.log"
ERR <- "/tmp/plan67-browser.err"

proc <- callr::r_bg(function(proj, port) {
  setwd(proj)
  suppressMessages({ library(shiny); library(shinyAssistantUI) })
  cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")
  shiny::runApp("tests/verify/cross_session_concurrency_app.R",
                host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = LOG, stderr = ERR)
on.exit({ try(proc$kill(), silent = TRUE); unlink(c(LOG, ERR)) }, add = TRUE)
for (i in seq_len(60L)) {
  if (!proc$is_alive()) {
    cat(readLines(ERR, warn = FALSE), sep = "\n")
    stop("fixture app exited during startup")
  }
  if (file.exists(LOG) && any(grepl("Listening on", readLines(LOG, warn = FALSE), fixed = TRUE))) break
  Sys.sleep(0.25)
}

chromote::set_chrome_args(c(chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"))
b <- ChromoteSession$new()
on.exit(try(b$close(), silent = TRUE), add = TRUE)
errors <- character()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) {
    errors <<- c(errors, paste(vapply(event$args, function(x)
      as.character(x$value %||% x$description %||% ""), character(1)), collapse = " "))
  }
})
b$Runtime$exceptionThrown(callback_ = function(event) {
  errors <<- c(errors, paste0("EXC: ", event$exceptionDetails$exception$description %||%
    event$exceptionDetails$text %||% "unknown"))
})
ev <- function(js) b$Runtime$evaluate(js)$result$value
wait_until <- function(js, timeout = 12, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    value <- tryCatch(ev(js), error = function(e) FALSE)
    if (isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
check <- function(name, condition, detail = "") {
  cat(sprintf("[%s] %-38s %s\n", if (isTRUE(condition)) "PASS" else "FAIL", name, detail))
  if (!isTRUE(condition)) stop(name, call. = FALSE)
}
click_thread <- function(label) {
  js <- sprintf("(()=>{const x=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes(%s));const trigger=x?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!trigger)return false;trigger.click();return true})()",
                jsonlite::toJSON(label, auto_unbox = TRUE))
  check(paste("select", label), wait_until(js))
  Sys.sleep(0.35)
}
send_text <- function(text) {
  check("composer available", wait_until("!!document.querySelector('[contenteditable=true]')"))
  check("composer send enabled", wait_until("!!document.querySelector('.aui-composer-send')", 8))
  ev("document.querySelector('[contenteditable=true]').focus()")
  b$Input$insertText(text = text)
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  Sys.sleep(0.25)
}
body_has <- function(text) grepl(text, ev("document.body.innerText"), fixed = TRUE)

b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
b$Page$loadEventFired()
check("installed widget mounted", wait_until("!!document.querySelector('.aui-root')", 20))
check("three historical sessions", wait_until("document.querySelectorAll('[data-slot=aui_thread-list-item]').length>=3", 15))

# Round 1: A waits for approval while B enters and completes independently.
click_thread("Alpha"); send_text("approval round")
check("A handler entered", wait_until("document.body.innerText.includes('A:start:approval round')", 8))
check("A entered approval", wait_until("!![...document.querySelectorAll('button')].find(b=>b.innerText.includes('Approve'))", 8))
click_thread("Beta"); send_text("quick B")
check("B starts while A waits", wait_until("document.body.innerText.includes('B:start:quick B')"))
check("B completes while A waits", wait_until("document.body.innerText.includes('B:final:quick B')", 8))
click_thread("Alpha")
check("A approval still pending", isTRUE(ev("!![...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve')")))
check("approve A", isTRUE(ev("(()=>{const x=[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve');if(!x)return false;x.click();return true})()")))
check("A completes after approval", wait_until("document.body.innerText.includes('A:approval:TRUE')", 8))

# Round 2: A/B occupy both permits, C queues; cancelling A admits C without harming B.
click_thread("Alpha"); send_text("long A")
click_thread("Beta"); send_text("long B")
check("A and B both started", wait_until("(()=>{const xs=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];const run=n=>!!xs.find(e=>e.innerText.includes(n))?.querySelector('[data-run-phase=running]');return run('Alpha')&&run('Beta')})()", 5))
click_thread("Gamma"); send_text("long C")
queued_js <- "(()=>{const x=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes('Gamma'));return !!x?.querySelector('[data-run-phase=queued]')})()"
check("C shows queued badge", wait_until(queued_js, 5))
click_thread("Alpha")
check("A shows Stop", wait_until("!!document.querySelector('.aui-composer-cancel')", 5))
check("cancel A", isTRUE(ev("(()=>{const x=document.querySelector('.aui-composer-cancel');if(!x)return false;x.click();return true})()")))
click_thread("Gamma")
check("C admitted after A cancel", wait_until("document.body.innerText.includes('C:start:long C')", 8))
click_thread("Beta")
check("B unaffected by A cancel", wait_until("document.body.innerText.includes('B:final:long B')", 8))
click_thread("Gamma")
check("C completes", wait_until("document.body.innerText.includes('C:final:long C')", 8))
click_thread("Alpha"); send_text("after cancel A")
check("A runs again after cancel", wait_until("document.body.innerText.includes('A:final:after cancel A')", 8))

# Reload must not restore an active phase.
b$Page$reload()
b$Page$loadEventFired(); Sys.sleep(2)
check("reload has no stale active badge", isTRUE(ev("document.querySelectorAll('[data-run-phase=queued],[data-run-phase=connecting],[data-run-phase=running]').length===0")))
check("zero console/runtime errors", length(errors) == 0L,
      if (length(errors)) paste(unique(errors), collapse = " | ") else "")
installed_line <- readLines(LOG, warn = FALSE)
check("Home installed package used", any(grepl("installed=/home/kaiping.yang/R/", installed_line, fixed = TRUE)))
cat("PLAN67_BROWSER_DONE\n")
