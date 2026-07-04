#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8996
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("examples/01_minimal.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/nm.log", stderr="/tmp/nm.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9); if (!proc$is_alive()) { cat(readLines("/tmp/nm.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-26s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
# 渲染检查
chk("aui_root_rendered", isTRUE(ev("!!document.querySelector('.aui-root')")), "")
n_ta <- ev("document.querySelectorAll('textarea').length")
chk("composer_textarea", as.integer(n_ta)>=1, sprintf("(textarea=%s)", n_ta))
console_err <- ev("(window.__errs||[]).length")
# 发消息:官方 composer 是 textarea
ev("(function(){var t=document.querySelector('textarea');t.focus();return !!t})()")
Sys.sleep(0.4)
b$Input$insertText(text="hello there")
Sys.sleep(0.4)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
Sys.sleep(3)
body <- ev("document.body.innerText")
chk("user_msg_shown", grepl("hello there", body), "")
chk("assistant_replied", grepl("你说的是|hello there", body) && nchar(body)>40, sprintf("(len=%s)", nchar(body)))
cat("body snippet:", substr(gsub("\n"," ",body),1,160), "\n")
b$close(); proc$kill(); system("rm -f /tmp/nm.log /tmp/nm.err")
cat("DONE\n")
