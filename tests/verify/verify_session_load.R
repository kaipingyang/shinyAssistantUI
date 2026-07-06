#!/usr/bin/env Rscript
# 复现/验证 React #31:历史会话含 file_path 工具时,加载渲染是否崩。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj, port){setwd(proj);readRenviron(file.path(proj,".Renviron"));suppressMessages(library(shiny));shiny::runApp("tests/verify/session_load_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
  args=list(proj=PROJ,port=9177), stdout="/tmp/sl.o", stderr="/tmp/sl.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/sl.e"),8),sep="\n");quit()}
errs <- c()
cap <- function(b){b$Runtime$enable();b$Runtime$consoleAPICalled(callback_=function(m){if(identical(m$type,"error"))errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" "))});b$Runtime$exceptionThrown(callback_=function(m){errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% m$exceptionDetails$text %||% ""))})}
ev <- function(b,js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)

# 阶段1:制造含 file_path 工具的会话
b1 <- chromote::ChromoteSession$new(); cap(b1)
b1$Page$navigate("http://127.0.0.1:9177/"); b1$Page$loadEventFired(); Sys.sleep(4)
ev(b1,"(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
b1$Input$insertText(text="Use the Write tool to create a file at /tmp/aui_repro.txt containing the text hello-world.")
Sys.sleep(0.3)
b1$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b1$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
for(i in 1:40){Sys.sleep(2);if(isTRUE(ev(b1,"!!document.querySelector('[data-slot=aui_usage_footer]')")))break}
cat("stage1 file tool used:", grepl("Write|file_path|aui_repro", ev(b1,"document.body.innerText")),"\n")
b1$close(); Sys.sleep(2)

# 阶段2:全新加载 → 会话加载器列历史 → 点开触发 onLoadThread 渲染
b2 <- chromote::ChromoteSession$new(); cap(b2)
b2$Page$navigate("http://127.0.0.1:9177/"); b2$Page$loadEventFired(); Sys.sleep(6)
nsess <- ev(b2,"document.querySelectorAll('[data-slot=aui_thread-list-item]').length")
cat("stage2 sidebar sessions:", nsess,"\n")
clicked_any <- FALSE
for(i in seq_len(min(as.integer(nsess %||% 0), 6))){
  r <- ev(b2, sprintf("(function(){var it=document.querySelectorAll('[data-slot=aui_thread-list-item]')[%d];if(!it)return null;var b=it.getBoundingClientRect();return JSON.stringify({x:b.x+20,y:b.y+b.height/2})})()", i-1))
  if(is.na(r)||is.null(r)) next
  xy<-jsonlite::fromJSON(r)
  b2$Input$dispatchMouseEvent(type="mousePressed",x=xy$x,y=xy$y,button="left",clickCount=1)
  b2$Input$dispatchMouseEvent(type="mouseReleased",x=xy$x,y=xy$y,button="left",clickCount=1)
  clicked_any<-TRUE; Sys.sleep(2.5)
  if(grepl("aui_repro|file_path|Write", ev(b2,"document.body.innerText"))) break
}
Sys.sleep(2)
react31 <- any(grepl("React error #31|error #31|not valid as a React child", errs))
cat(sprintf("[%s] no_react31_crash (react31=%s)\n", if(!react31)"PASS" else "FAIL", react31))
aui <- as.integer(ev(b2,"document.querySelectorAll('.aui-root').length"))
cat(sprintf("[%s] widget_still_rendered (aui-root=%s)\n", if(!is.na(aui)&&aui>=1)"PASS" else "FAIL", aui))
cat("clicked_any_session:", clicked_any,"\n")
if(length(errs)) { cat("=== console errors (head) ===\n"); cat(head(unique(errs),4),sep="\n") }
b2$close(); p$kill(); system("rm -f /tmp/sl.* /tmp/aui_repro.txt")
cat("SL_DONE\n")
