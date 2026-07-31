# Plan 47 A0 无头验证:R 经 on_data_ui 下发 → 前端 DATA_UI_BY_NAME 渲染 table/stat/flow。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9841L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/data_ui_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/du.o",stderr="/tmp/du.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/du.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
b$Runtime$exceptionThrown(callback_=function(m) errs<<-c(errs, m$exceptionDetails$exception$description %||% "exception"))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
ev("(function(){var t=document.querySelector('.aui-lexical-input[contenteditable=true],[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="go")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
for(i in 1:25){Sys.sleep(0.5); if(isTRUE(ev("!!document.querySelector('[data-slot=data-table]')"))) break}
has_table <- isTRUE(ev("!!document.querySelector('[data-slot=data-table]')"))
tbl_txt   <- ev("document.querySelector('[data-slot=data-table]')?.textContent||''") %||% ""
has_stat  <- isTRUE(ev("(document.querySelector('[data-slot=data-stat]')?.textContent||'').includes('0.87')"))
has_flow  <- isTRUE(ev("!!document.querySelector('[data-slot=data-flow]') && !!document.querySelector('[data-flow-id=load]') && !!document.querySelector('[data-flow-id=model]')"))
cat(sprintf("[%s] data-table rendered with rows (age/bmi/1.2)\n", if(has_table && grepl("age",tbl_txt) && grepl("bmi",tbl_txt) && grepl("1.2",tbl_txt))"PASS" else "FAIL"))
cat(sprintf("[%s] data-stat rendered (R2 0.87)\n", if(has_stat)"PASS" else "FAIL"))
cat(sprintf("[%s] data-flow revived FlowCanvas (nodes load/model)\n", if(has_flow)"PASS" else "FAIL"))
# Rule #1c:session-load 复原路径——重载页面,历史消息里的 data part 重放渲染
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(5)
reloaded <- isTRUE(ev("!!document.querySelector('[data-slot=data-table]') && !!document.querySelector('[data-slot=data-flow]')"))
cat(sprintf("[%s] session-load restore: data parts re-render from history\n", if(reloaded)"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "), "\n")
b$close();p$kill();system("rm -f /tmp/du.*")
cat("DATA_UI_VERIFY_DONE\n")
