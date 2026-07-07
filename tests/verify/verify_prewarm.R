#!/usr/bin/env Rscript
# 验证预热:
#  A) example 11(prewarm=TRUE 默认):挂载时预热(指示器欢迎屏出现→消失),之后首条消息【不再】显示冷启动指示器。
#  B) prewarm_off_app(prewarm=FALSE):挂载不预热,首条消息【仍】显示冷启动指示器。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
run_app <- function(appfile, port) callr::r_bg(function(proj,app,port){setwd(proj);readRenviron(file.path(proj,".Renviron"));suppressMessages(library(shiny));shiny::runApp(app,host="127.0.0.1",port=port,launch.browser=FALSE)}, args=list(proj=PROJ,app=appfile,port=port), stdout=sprintf("/tmp/pw%d.o",port), stderr=sprintf("/tmp/pw%d.e",port))
ev <- function(b,js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
send <- function(b,txt){ev(b,"(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()");Sys.sleep(0.4);b$Input$insertText(text=txt);Sys.sleep(0.3);b$Input$dispatchKeyEvent(type='keyDown',key='Enter',code='Enter',windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type='keyUp',key='Enter',code='Enter',windowsVirtualKeyCode=13L)}
chk<-function(n,c,d="")cat(sprintf("[%s] %-34s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))

pA <- run_app("examples/11_tool_calling_claude_sdk.R", 9173); Sys.sleep(12)
if(!pA$is_alive()){cat("BOOT FAIL A\n")} else {
  bA<-chromote::ChromoteSession$new(); bA$Page$navigate("http://127.0.0.1:9173/"); bA$Page$loadEventFired(); Sys.sleep(3)
  ev(bA,"(function(){window.__mw=false;window.__r=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__mw=true},20);return true})()")
  for(i in 1:20){Sys.sleep(1);if(isTRUE(ev(bA,"window.__mw")) && !isTRUE(ev(bA,"!!document.querySelector('[data-slot=aui_warming]')")))break}
  chk("A_prewarm_indicator_at_mount", isTRUE(ev(bA,"window.__mw")))
  chk("A_prewarm_done_before_msg", !isTRUE(ev(bA,"!!document.querySelector('[data-slot=aui_warming]')")))
  ev(bA,"window.__msgw=false;window.__r2=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__msgw=true},20);")
  send(bA,"say hi in 2 words")
  for(i in 1:25){Sys.sleep(1);if(isTRUE(ev(bA,"!!document.querySelector('[data-slot=aui_usage_footer]')")))break}
  chk("A_first_msg_no_cold_indicator", !isTRUE(ev(bA,"window.__msgw")))
  try(bA$close(),silent=TRUE); try(bA$parent$get_browser()$get_process()$kill(),silent=TRUE)
}
try(pA$kill(),silent=TRUE); Sys.sleep(2)

pB <- run_app("tests/verify/prewarm_off_app.R", 9172); Sys.sleep(12)
if(!pB$is_alive()){cat("BOOT FAIL B\n")} else {
  bB<-chromote::ChromoteSession$new(); bB$Page$navigate("http://127.0.0.1:9172/"); bB$Page$loadEventFired(); Sys.sleep(4)
  ev(bB,"(function(){window.__mw=false;window.__r=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__mw=true},20);return true})()")
  Sys.sleep(4)
  chk("B_no_prewarm_at_mount", !isTRUE(ev(bB,"window.__mw")))
  ev(bB,"window.__msgw=false;window.__r2=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__msgw=true},20);")
  send(bB,"say hi in 2 words")
  for(i in 1:25){Sys.sleep(1);if(isTRUE(ev(bB,"!!document.querySelector('[data-slot=aui_usage_footer]')")))break}
  chk("B_first_msg_shows_cold_indicator", isTRUE(ev(bB,"window.__msgw")))
  try(bB$close(),silent=TRUE); try(bB$parent$get_browser()$get_process()$kill(),silent=TRUE)
}
try(pB$kill(),silent=TRUE); system("rm -f /tmp/pw*.o /tmp/pw*.e")
cat("PW_DONE\n")
