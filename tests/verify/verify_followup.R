# Plan 48B e2e (headless): after an assistant reply, R-pushed follow-up chips (via
# on_suggestions) render BELOW the latest reply; clicking one replaces the composer and
# sends it (autoSend). Echo fixture (GOT[<message>]) so the click's send is observable.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9934L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/followup_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/vf.o",stderr="/tmp/vf.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/vf.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/vf.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(){b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
lastReply<-function()ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
waitReply<-function(prev){for(i in 1:40){Sys.sleep(0.25);r<-lastReply();if(nzchar(r)&&!identical(r,prev)&&grepl('GOT\\[',r))return(r)};lastReply()}
chips<-function()ev("(function(){return [].slice.call(document.querySelectorAll('.aui-thread-followup-suggestion')).map(function(e){return e.innerText.trim()}).join('|')})()") %||% ""
waitChips<-function(){for(i in 1:40){Sys.sleep(0.25);c<-chips();if(nzchar(c))return(c)};chips()}
type<-function(t){ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()");Sys.sleep(0.2);b$Input$insertText(text=t);Sys.sleep(0.2)}
PASS<-TRUE; ok<-function(cond,label){cat(sprintf("[%s] %s\n",if(isTRUE(cond))"PASS" else {PASS<<-FALSE;"FAIL"},label))}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)

# 1) 发一条 → 拿到回复
type("hello"); key(); r1<-waitReply("")
ok(grepl("GOT\\[hello\\]",r1), sprintf("reply arrived (%s)", substr(gsub("\n"," ",r1),1,22)))

# 2) 回复后 follow-up chip 出现在下方(run 结束后,门禁 !isRunning)
cs<-waitChips()
ok(grepl("do A",cs) && grepl("do B",cs), sprintf("follow-up chips rendered below reply (%s)", cs))

# 3) chip 不该在流式中/空线程出现——此处 thread 非空、已结束,应可见(上一步已验)。
#    点击 "do A" chip → autoSend 把它作为新消息发送 → 新回复 GOT[do A]
clicked<-ev("(function(){var els=[].slice.call(document.querySelectorAll('.aui-thread-followup-suggestion'));var t=els.filter(function(e){return e.innerText.trim()==='do A'})[0];if(t){t.click();return true}return false})()")
ok(isTRUE(clicked), "clicked 'do A' chip")
r2<-waitReply(r1)
ok(grepl("GOT\\[do A\\]",r2), sprintf("chip click sent the prompt (%s)", substr(gsub("\n"," ",r2),1,22)))

ok(length(errs)==0, sprintf("no console errors (%d)", length(errs)))
if(length(errs)) cat("  ERRORS:\n   ", paste(head(errs,5),collapse="\n    "),"\n")
b$close(); p$kill()
cat(if(PASS)"FOLLOWUP_VERIFY_PASS\n" else "FOLLOWUP_VERIFY_FAIL\n")
