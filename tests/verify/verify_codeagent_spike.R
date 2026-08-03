# Plan 51 A make-or-break 验证:真实 codeagent_stream_async 在 assistantUIServer ExtendedTask 里,
# 端到端流式 → assistant 气泡出现文本 + 0 console error + 回合完成(不卡死)。真 LLM。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9857L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("examples/codeagent-backend-spike.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/ca.o",stderr="/tmp/ca.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/ca.e"),15),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="Reply with exactly: hello there friend")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
# 真 LLM:等真实文本(不被 ● 工作指示符/动作按钮误判);最多 ~50s
clean<-function(s) trimws(gsub("Copy|Refresh|More|\u25CF","",s %||% ""))
got<-""; for(i in 1:100){Sys.sleep(0.5); raw<-ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');if(!a.length)return '';return a[a.length-1].innerText||''})()") %||% ""; if(grepl("[A-Za-z]{3}", clean(raw))){got<-raw; break}}
Sys.sleep(2); got<-ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');if(!a.length)return '';return a[a.length-1].innerText||''})()") %||% ""
cat("assistant text:", gsub("\n"," ",substr(clean(got),1,140)), "\n")
cat(sprintf("[%s] real codeagent turn streamed assistant text in ExtendedTask\n", if(grepl("hello", got, ignore.case=TRUE) || nchar(clean(got))>2)"PASS" else "FAIL"))
running<-isTRUE(ev("!!document.querySelector('[data-status=running],.aui-thread-running')"))
cat(sprintf("[%s] turn completed (not stuck running)\n", if(!running)"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "),"\n")
if(!p$is_alive()) cat("  (app process died mid-turn!)\n")
b$close();p$kill();system("rm -f /tmp/ca.*")
cat("CODEAGENT_SPIKE_DONE\n")
