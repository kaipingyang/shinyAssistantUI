# 验证 usage 环显示 context_tokens(当前占用 31%),非 tokens(累计 92%)。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9820L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/usage_ring_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/ur.o",stderr="/tmp/ur.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/ur.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
ev("(function(){var t=document.querySelector('.aui-lexical-input[contenteditable=true],[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="go")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
for(i in 1:20){Sys.sleep(0.6); if(isTRUE(ev("!!document.querySelector('[data-slot=context-display-trigger]')"))) break}
# 打开 tooltip 读百分比/tokens
ev("(function(){var t=document.querySelector('[data-slot=context-display-trigger]');if(t){t.focus();t.dispatchEvent(new PointerEvent('pointermove',{bubbles:true}));t.dispatchEvent(new PointerEvent('pointerenter',{bubbles:true}))}return !!t})()");Sys.sleep(1.2)
body <- ev("document.body.innerText") %||% ""
ring <- ev("(function(){var e=document.querySelector('[data-slot=context-display-popover]');return e?e.innerText:''})()") %||% ""
cat("ring tooltip:", gsub("\n"," ",substr(ring,1,90)), "\n")
cat(sprintf("[%s] ring shows current-context ~31%% / 305.9k (context_tokens)\n", if(grepl("30\\.6%|31%|305",ring))"PASS" else "FAIL"))
cat(sprintf("[%s] ring is NOT the cumulative 92%%/915k (tokens)\n", if(!grepl("92%|91\\.5%|915",ring))"PASS" else "FAIL"))
# footer 仍显示累计 tokens(915,100)
cat(sprintf("[%s] footer keeps cumulative tokens (915,100)\n", if(grepl("915,100|915100",body))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close();p$kill();system("rm -f /tmp/ur.*")

# --- 负例(B 核心):只发 context_tokens、不发真实窗口 → 环【不显示】,绝不猜分母 ---
PORT2<-PORT+1L
p2<-callr::r_bg(function(proj,port){setwd(proj);Sys.setenv(AUI_NOWINDOW="1");suppressMessages(library(shiny));shiny::runApp("tests/verify/usage_ring_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT2),stdout="/tmp/ur2.o",stderr="/tmp/ur2.e")
on.exit(try(p2$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
b2<-chromote::ChromoteSession$new();b2$Runtime$enable()
ev2<-function(js)tryCatch(b2$Runtime$evaluate(js)$result$value,error=function(e)NA)
b2$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT2));b2$Page$loadEventFired();Sys.sleep(4)
ev2("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b2$Input$insertText(text="go")
b2$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b2$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
Sys.sleep(6)
no_ring <- isTRUE(ev2("!document.querySelector('[data-slot=context-display-trigger]')"))
cat(sprintf("[%s] no context_window -> ring NOT shown (never guesses denominator)\n", if(no_ring)"PASS" else "FAIL"))
b2$close();p2$kill();system("rm -f /tmp/ur2.*")
cat("USAGE_RING_DONE\n")

