#!/usr/bin/env Rscript
# 验证 serverTool 徽章 + 审批 title/displayName/description(fixture 契约)。
suppressMessages({library(chromote);library(callr)})
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/server_tool_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=9192), stdout="/tmp/stv.o", stderr="/tmp/stv.e")
on.exit(try(p$kill(), silent=TRUE), add=TRUE); Sys.sleep(10)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/stv.e"),8),sep="\n"); quit() }
b <- chromote::ChromoteSession$new()
b$Page$navigate("http://127.0.0.1:9192/"); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-30s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
send <- function(txt){ ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
  b$Input$insertText(text=txt); Sys.sleep(0.3)
  b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L) }

# 1) 服务端工具卡
send("please search the web")
ok <- FALSE; for (i in 1:12) { Sys.sleep(1); if (isTRUE(ev("!!document.querySelector('[data-server-tool]')"))) { ok<-TRUE; break } }
chk("server_tool_badge", ok, ev("(function(){var e=document.querySelector('[data-server-tool]');return e?e.innerText:'(none)'})()"))
chk("server_tool_name_shown", grepl("web_search", ev("document.body.innerText")))

# 2) 审批字段(新会话)
Sys.sleep(1); send("delete the file")
ok2 <- FALSE; for (i in 1:12) { Sys.sleep(1); if (isTRUE(ev("!!document.querySelector('[data-approval-title]')"))) { ok2<-TRUE; break } }
chk("approval_title", ok2, ev("(function(){var e=document.querySelector('[data-approval-title]');return e?e.innerText:'(none)'})()"))
chk("approval_displayname", isTRUE(ev("!!document.querySelector('[data-approval-displayname]')")), ev("(function(){var e=document.querySelector('[data-approval-displayname]');return e?e.innerText:'(none)'})()"))
chk("approval_description", isTRUE(ev("!!document.querySelector('[data-approval-description]')")), ev("(function(){var e=document.querySelector('[data-approval-description]');return e?e.innerText:'(none)'})()"))
# 按钮标签仍严格 Approve(不被字段改动破坏)
chk("approve_button_intact", isTRUE(ev("Array.from(document.querySelectorAll('button')).some(b=>/^\\s*Approve\\s*$/.test(b.innerText))")))

try(b$close(), silent=TRUE); try(p$kill(), silent=TRUE)
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(), silent=TRUE)
system("rm -f /tmp/stv.*")
cat("SERVER_TOOL_VERIFY_DONE\n")
