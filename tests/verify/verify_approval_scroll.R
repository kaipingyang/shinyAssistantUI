# Issue 1 验证:连续审批时,每个新审批框自动滚进视口(无需手动下滑)。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9831L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/approval_scroll_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/as.o",stderr="/tmp/as.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/as.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
ev("(function(){var t=document.querySelector('.aui-lexical-input[contenteditable=true],[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.3)
b$Input$insertText(text="go")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
# 最新审批框是否在视口内(bottom 可见)
approval_in_view<-function(){
  ev("(function(){var v=document.querySelector('[data-slot=aui_thread-viewport]');var as=document.querySelectorAll('.aui-shiny-approval');if(!v||!as.length)return null;var a=as[as.length-1];var vr=v.getBoundingClientRect();var ar=a.getBoundingClientRect();return (ar.bottom<=vr.bottom+12 && ar.bottom>=vr.top)})()")
}
inview<-c()
for(k in 1:4){
  ok<-FALSE
  for(i in 1:24){Sys.sleep(0.5); r<-approval_in_view(); if(!is.na(r)&&isTRUE(r)){ok<-TRUE;break}; if(!is.na(r)&&isFALSE(r)){ok<-FALSE;break}}
  inview<-c(inview, ok)
  # 点最新审批框里的 Approve
  ev("(function(){var as=document.querySelectorAll('.aui-shiny-approval');if(!as.length)return false;var a=as[as.length-1];var btns=[...a.querySelectorAll('button')];var ap=btns.find(x=>/^Approve/.test(x.innerText.trim()));if(ap)ap.click();return !!ap})()")
  Sys.sleep(1.5)
}
cat("per-approval in-view:", paste(inview, collapse=","), "\n")
cat(sprintf("[%s] every new approval auto-scrolled into view\n", if(all(inview))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat(head(unique(errs),3),sep="\n")
b$close();p$kill();system("rm -f /tmp/as.*")
cat("APPROVAL_SCROLL_DONE\n")
