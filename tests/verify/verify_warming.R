#!/usr/bin/env Rscript
# 验证每线程冷启动指示器:首条消息冷启动时出现,连上后消失,同线程第二条不再出现。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj,port){setwd(proj);readRenviron(file.path(proj,".Renviron"));suppressMessages(library(shiny));shiny::runApp("examples/11_tool_calling_claude_sdk.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
  args=list(proj=PROJ,port=9174), stdout="/tmp/wm.o", stderr="/tmp/wm.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");quit()}
b <- chromote::ChromoteSession$new(); errs<-c()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m){if(identical(m$type,"error"))errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" "))})
b$Runtime$exceptionThrown(callback_=function(m){errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% ""))})
b$Page$navigate("http://127.0.0.1:9174/"); b$Page$loadEventFired(); Sys.sleep(4)
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
chk<-function(n,c,d="")cat(sprintf("[%s] %-30s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))
send<-function(txt){ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()");Sys.sleep(0.4);b$Input$insertText(text=txt);Sys.sleep(0.3);b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
# 20ms 记录器:捕获 warming 指示器是否出现过
ev("(function(){window.__w1=false;window.__rec=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__w1=true},20);return true})()")

# 第一条(冷启动)
send("say hi in 2 words")
for(i in 1:30){Sys.sleep(1);if(isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')")))break}
Sys.sleep(1)
chk("cold_start_indicator_shown", isTRUE(ev("window.__w1")))
chk("indicator_gone_after_connect", !isTRUE(ev("!!document.querySelector('[data-slot=aui_warming]')")))

# 第二条(同线程,已连接 → 不该再冷启动)
ev("window.__w2=false; window.__rec2=setInterval(function(){if(document.querySelector('[data-slot=aui_warming]'))window.__w2=true},20);")
send("say bye in 2 words")
for(i in 1:20){Sys.sleep(1);if(isTRUE(ev("(function(){var xs=document.querySelectorAll('[data-slot=aui_usage_footer]');return xs.length>=1})()")))break}
Sys.sleep(2)
chk("no_indicator_on_warm_second_msg", !isTRUE(ev("window.__w2")))
chk("no_react_crash", !any(grepl("React error #31|not valid as a React child|Minified React",errs)))
if(length(errs)) { cat("=== console errors ===\n"); cat(head(unique(errs),3),sep="\n") }
b$close();p$kill();system("rm -f /tmp/wm.*")
cat("WM_DONE\n")
