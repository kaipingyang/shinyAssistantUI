# 验证切目录重载 skills:send_commands 热更新 slash 菜单(alphacmd → betacmd)。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9823L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/commands_reload_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/cr.o",stderr="/tmp/cr.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/cr.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(5)
open_slash<-function(){
  ev("(function(){var t=document.querySelector('.aui-lexical-input[contenteditable=true],[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.3)
  b$Input$insertText(text="/");Sys.sleep(0.8)
}
menu_text<-function() ev("(function(){var m=document.querySelector('.aui-slash-popover');return m?m.innerText:''})()") %||% ""
open_slash(); t1<-menu_text()
cat("menu#1:", gsub("\n"," ",substr(t1,1,60)),"\n")
cat(sprintf("[%s] initial slash menu has alphacmd\n", if(grepl("alphacmd",t1))"PASS" else "FAIL"))
# 清掉 "/" 并关菜单
b$Input$dispatchKeyEvent(type="keyDown",key="Backspace",code="Backspace",windowsVirtualKeyCode=8L)
b$Input$dispatchKeyEvent(type="keyUp",key="Backspace",code="Backspace",windowsVirtualKeyCode=8L)
b$Input$dispatchKeyEvent(type="keyDown",key="Escape",code="Escape",windowsVirtualKeyCode=27L);Sys.sleep(0.3)
# 点 swap → send_commands(betacmd)
ev("(function(){var b=document.getElementById('swap');if(b)b.click();return !!b})()");Sys.sleep(1.2)
open_slash(); t2<-menu_text()
cat("menu#2:", gsub("\n"," ",substr(t2,1,60)),"\n")
cat(sprintf("[%s] slash menu hot-updated to betacmd\n", if(grepl("betacmd",t2))"PASS" else "FAIL"))
cat(sprintf("[%s] old alphacmd gone after reload\n", if(!grepl("alphacmd",t2))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close();p$kill();system("rm -f /tmp/cr.*")
cat("COMMANDS_RELOAD_DONE\n")
