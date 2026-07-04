#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8991
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/timestamps_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/ts.log", stderr="/tmp/ts.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9); if (!proc$is_alive()) { cat(readLines("/tmp/ts.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-24s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
# 发消息
ev("document.querySelector('[contenteditable=true]').focus()"); Sys.sleep(0.5)
b$Input$insertText(text = "hello")
Sys.sleep(0.5)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
Sys.sleep(3)
n_ts <- ev("document.querySelectorAll('.aui-message-timestamp').length")
cat("timestamp count:", n_ts, "\n")
chk("timestamps_rendered", as.integer(n_ts) >= 1, sprintf("(count=%s)", n_ts))
fmt_ok <- ev("Array.from(document.querySelectorAll('.aui-message-timestamp')).every(e=>/^\\d\\d:\\d\\d$/.test(e.getAttribute('data-timestamp')))")
chk("timestamp_format_HHMM", isTRUE(fmt_ok), ev("document.querySelector('.aui-message-timestamp')?document.querySelector('.aui-message-timestamp').getAttribute('data-timestamp'):'none'"))
b$close(); proc$kill(); system("rm -f /tmp/ts.log /tmp/ts.err")
cat("DONE\n")
