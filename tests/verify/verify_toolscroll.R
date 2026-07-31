# Bug2/3 验证:tool 调用 + 流式时 viewport 自动滚到底(auto_200px containment 修复)。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9801L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/toolscroll_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/ts.o",stderr="/tmp/ts.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/ts.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
# 发一条消息触发 handler
ev("(function(){var t=document.querySelector('.aui-lexical-input[contenteditable=true],[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="go")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
# 等 handler 跑完(TAIL_AFTER_TOOL 出现)
done<-FALSE; for(i in 1:40){Sys.sleep(0.5); if(grepl("TAIL_AFTER_TOOL", ev("document.body.innerText") %||% "")){done<-TRUE;break}}
Sys.sleep(1.5)  # 给 autoscroll 收敛
cat("handler finished:", done, "\n")
gap<-ev("(function(){var v=document.querySelector('[data-slot=aui_thread-viewport]');if(!v)return -1;return Math.round(v.scrollHeight - v.scrollTop - v.clientHeight)})()")
cat("viewport distance-from-bottom(px):", gap, "\n")
cat(sprintf("[%s] viewport auto-scrolled to bottom after tool (gap<=60px)\n", if(!is.na(gap)&&gap>=0&&gap<=60)"PASS" else "FAIL"))
# tool 卡渲染了
cat(sprintf("[%s] tool card rendered\n", if(isTRUE(ev("!!document.querySelector('.aui-shiny-tool')")))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat(head(unique(errs),3),sep="\n")
b$close();p$kill();system("rm -f /tmp/ts.*")
cat("TOOLSCROLL_DONE\n")
