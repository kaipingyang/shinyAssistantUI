#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
`%||%` <- function(x, y) if (is.null(x)) y else x

args_all <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args_all, value = TRUE)
script_path <- if (length(file_arg)) {
  normalizePath(sub("^--file=", "", file_arg[[1L]]))
} else {
  normalizePath("tests/verify/verify_addin_runtime_refresh.R")
}
PROJ <- normalizePath(file.path(dirname(script_path), "../.."))
PORT <- httpuv::randomPort()
LOG_OUT <- tempfile(paste0("addin-runtime-refresh-", Sys.getpid(), "-"), fileext = ".out")
LOG_ERR <- tempfile(paste0("addin-runtime-refresh-", Sys.getpid(), "-"), fileext = ".err")
on.exit(unlink(c(LOG_OUT, LOG_ERR)), add = TRUE)

proc <- callr::r_bg(function(proj, port) {
  suppressMessages({ library(shiny); library(shinyAssistantUI) })
  app <- source(file.path(proj, "tests/verify/addin_runtime_refresh_app.R"), local = new.env())$value
  shiny::runApp(app, host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = LOG_OUT, stderr = LOG_ERR)
on.exit(try(proc$kill(), silent = TRUE), add = TRUE)

for (i in 1:100) {
  if (!proc$is_alive()) break
  if (file.exists(LOG_ERR) && any(grepl("Listening on", readLines(LOG_ERR, warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!proc$is_alive()) {
  cat("BOOT FAIL\n")
  if (file.exists(LOG_ERR)) cat(tail(readLines(LOG_ERR, warn = FALSE), 20), sep = "\n")
  quit(status = 1)
}

chromote::set_chrome_args(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
))
b <- chromote::ChromoteSession$new()
on.exit(try(b$close(), silent = TRUE), add = TRUE)
errors <- character()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    errors <<- c(errors, paste(vapply(message$args, function(arg)
      as.character(arg$value %||% arg$description %||% ""), character(1)), collapse = " "))
  }
})
b$Runtime$exceptionThrown(callback_ = function(message) {
  details <- message$exceptionDetails
  errors <<- c(errors, paste("EXC:", details$exception$description %||% details$text %||% ""))
})

b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
b$Page$loadEventFired()
Sys.sleep(3)
ev <- function(js) b$Runtime$evaluate(js)$result$value
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-42s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) stop(name, call. = FALSE)
}
wait_until <- function(js, timeout = 8) {
  deadline <- Sys.time() + timeout
  repeat {
    value <- tryCatch(ev(js), error = function(e) FALSE)
    if (isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.1)
  }
}
handler_messages <- function() {
  if (!file.exists(LOG_ERR)) return(character())
  lines <- grep("^\\[HANDLER\\]", readLines(LOG_ERR, warn = FALSE), value = TRUE)
  trimws(sub("^\\[HANDLER\\]\\s*", "", lines))
}
wait_handler_count <- function(expected, timeout = 8) {
  deadline <- Sys.time() + timeout
  repeat {
    if (length(handler_messages()) >= expected) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.1)
  }
}
editor_focus <- function() {
  check("addin composer exists", isTRUE(ev("(function(){var e=document.querySelector('#chat [contenteditable=true]');if(!e)return false;e.focus();return true})()")))
}
send_text <- function(text) {
  editor_focus()
  b$Input$insertText(text = text)
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  Sys.sleep(0.2)
}
clear_editor <- function() {
  editor_focus()
  b$Input$dispatchKeyEvent(type = "keyDown", key = "a", code = "KeyA", modifiers = 2L)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "a", code = "KeyA", modifiers = 2L)
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "Backspace", code = "Backspace", windowsVirtualKeyCode = 8L)
}

check("two widgets mounted", ev("document.querySelectorAll('.aui-root').length") >= 2)
check("service status visible", isTRUE(ev("!!document.querySelector('#chat [data-slot=aui_service_status][data-status=starting]')")) ||
  isTRUE(ev("!!document.querySelector('#chat [data-slot=aui_service_status][data-status=checking]')")))
check("composer editable during startup", identical(ev("document.querySelector('#chat [contenteditable=true]').getAttribute('contenteditable')"), "true"))
check("generic widget has no service UI", !isTRUE(ev("!!document.querySelector('#plain [data-slot=aui_service_status]')")))

send_text("first queued")
send_text("second queued")
check("pre-ready backend count remains zero", length(handler_messages()) == 0L)
check("pending count is two", grepl("2 submissions waiting", ev("document.querySelector('#chat [data-slot=aui_service_status]').innerText"), fixed = TRUE))
ev("(function(){Shiny.setInputValue('service_ready',Date.now(),{priority:'event'});return true})()")
check("queued submissions delivered", wait_handler_count(2L, 10))
check("queued submissions preserve FIFO", identical(handler_messages(), c("first queued", "second queued")))
Sys.sleep(0.8)
check("queued submissions exactly once", length(handler_messages()) == 2L)
check("service reaches ready", isTRUE(ev("!!document.querySelector('#chat [data-slot=aui_service_status][data-status=ready]')")))
check("ready status is compact below composer", isTRUE(ev(paste0(
  "(function(){var s=document.querySelector('#chat [data-slot=aui_service_status][data-status=ready]'),",
  "c=document.querySelector('#chat [data-slot=aui_composer-shell]');if(!s||!c)return false;",
  "var sr=s.getBoundingClientRect(),cr=c.getBoundingClientRect();",
  "return s.dataset.compact==='true'&&sr.top>=cr.bottom-1&&sr.height<=28})()"
))))
check("ready checkmark is visibly green", isTRUE(ev(paste0(
  "(function(){var i=document.querySelector('#chat [data-slot=aui_service_ready_icon]');",
  "return !!i&&/text-green-/.test(i.className)})()"
))))

# Authoritative server command snapshots: old -> [] -> new.
ev("document.getElementById('commands_old').click()")
Sys.sleep(0.3)
clear_editor(); b$Input$insertText(text = "/"); Sys.sleep(0.4)
check("old command snapshot shown", isTRUE(ev("!!document.querySelector('#chat [data-slash-cmd=oldcmd]')")))
ev("document.getElementById('commands_clear').click()")
Sys.sleep(0.4)
check("empty command snapshot clears old", !isTRUE(ev("!!document.querySelector('#chat [data-slash-cmd=oldcmd]')")))
ev("document.getElementById('commands_new').click()")
Sys.sleep(0.4)
check("replacement command snapshot shown", isTRUE(ev("!!document.querySelector('#chat [data-slash-cmd=newcmd]')")))
clear_editor()

# Restore historical tool messages and derive the pinned checklist.
check("history item exists", wait_until("Array.from(document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')).some(e=>e.innerText.includes('Checklist history'))"))
ev("(function(){var e=Array.from(document.querySelectorAll('#chat [data-slot=aui_thread-list-item]')).find(e=>e.innerText.includes('Checklist history'));if(e)e.querySelector('[data-slot=aui_thread-list-item-trigger]').click();return !!e})()")
check("historical checklist restored", wait_until("document.querySelectorAll('#chat [data-slot=aui_claude_checklist] li').length===2"))
check("completed checklist offers close", isTRUE(ev("!!document.querySelector('#chat [aria-label=\"Dismiss completed checklist\"]')")))
ev("document.querySelector('#chat [aria-label=\"Dismiss completed checklist\"]')?.click();true")
check("user can close completed checklist", wait_until("!document.querySelector('#chat [data-slot=aui_claude_checklist]')"))

before_new_task <- length(handler_messages())
send_text("new checklist task")
check(
  "new checklist task reaches handler",
  wait_handler_count(before_new_task + 1L, 10),
  paste(handler_messages(), collapse = "|")
)
check(
  "new task revision reopens checklist",
  wait_until("!!document.querySelector('#chat [data-slot=aui_claude_checklist][data-all-completed=false]')"),
  ev("JSON.stringify({messages:[...document.querySelectorAll('#chat [data-role]')].map(e=>e.innerText),checklists:[...document.querySelectorAll('#chat [data-slot=aui_claude_checklist]')].map(e=>({revision:e.dataset.checklistRevision,completed:e.dataset.allCompleted,text:e.innerText}))})")
)
check("active checklist has no close action", !isTRUE(ev("!!document.querySelector('#chat [aria-label=\"Dismiss completed checklist\"]')")))
check("checklist stays above composer without overlap", isTRUE(ev(paste0(
  "(function(){var k=document.querySelector('#chat [data-slot=aui_claude_checklist]'),",
  "c=document.querySelector('#chat [data-slot=aui_composer-shell]');if(!k||!c)return false;",
  "var kr=k.getBoundingClientRect(),cr=c.getBoundingClientRect();return kr.bottom<=cr.top+1})()"
))))
check("latest output remains above sticky footer", isTRUE(ev(paste0(
  "(function(){var m=[...document.querySelectorAll('#chat [data-role=assistant]')].at(-1),",
  "f=document.querySelector('#chat [data-slot=aui_thread-viewport-footer]');if(!m||!f)return false;",
  "var mr=m.getBoundingClientRect(),fr=f.getBoundingClientRect();return mr.bottom<=fr.top+2})()"
))))

send_text("complete checklist")
check("Claude can complete the live checklist", wait_until("!!document.querySelector('#chat [data-slot=aui_claude_checklist][data-all-completed=true]')"))
send_text("plain followup")
check("next non-task turn auto-hides completed checklist", wait_until("!document.querySelector('#chat [data-slot=aui_claude_checklist]')"))

# Enhanced current-session SDK task card and duplicate-stop guard.
ev("document.getElementById('task_start').click()")
check("task monitor card rendered", wait_until("!!document.querySelector('#chat [data-task-id=browser-task]')"))
ev("document.querySelector('#chat [data-stop-task=browser-task]').click()")
Sys.sleep(0.3)
check("task stop enters stopping state", identical(ev("document.querySelector('#chat [data-stop-task=browser-task]').innerText"), "Stopping…"))
check("task stop disabled after first click", isTRUE(ev("document.querySelector('#chat [data-stop-task=browser-task]').disabled")))

check("zero browser console/runtime errors", length(errors) == 0L,
      if (length(errors)) paste(unique(errors), collapse = " | ") else "")

cat("ADDIN_RUNTIME_REFRESH_VERIFY_DONE\n")
try(b$close(), silent = TRUE)
try(proc$kill(), silent = TRUE)
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(), silent = TRUE)
unlink(c(LOG_OUT, LOG_ERR))
