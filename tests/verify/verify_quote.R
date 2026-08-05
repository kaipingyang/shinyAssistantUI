# Plan 48A e2e (headless): select text in an assistant reply -> Quote toolbar -> click ->
# ComposerQuotePreview shows the quote -> type follow-up + send -> R receives the quote and
# .prepend_quote injects it as a markdown blockquote before the message. Echo fixture
# (handler replies GOT[<message>]) so the final reply reveals the injected "> <quote>".
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9931L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/attach_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/vq.o",stderr="/tmp/vq.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/vq.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/vq.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(){b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
lastReply<-function()ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
waitReply<-function(prev){for(i in 1:40){Sys.sleep(0.25);r<-lastReply();if(nzchar(r)&&!identical(r,prev)&&grepl('GOT\\[',r))return(r)};lastReply()}
type<-function(t){ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()");Sys.sleep(0.2);b$Input$insertText(text=t);Sys.sleep(0.2)}
PASS<-TRUE; ok<-function(cond,label){cat(sprintf("[%s] %s\n",if(isTRUE(cond))"PASS" else {PASS<<-FALSE;"FAIL"},label))}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)

# 1) 先发一条,拿到助手回复 GOT[hello]
type("hello"); key(); r1<-waitReply("")
ok(grepl("GOT\\[hello\\]",r1), sprintf("first reply arrived (%s)", substr(gsub("\n"," ",r1),1,24)))

# 2) 在助手回复里划选文本 → 触发 SelectionToolbar
sel<-ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');if(!a.length)return 'NO_ASSISTANT';var el=a[a.length-1];var r=document.createRange();r.selectNodeContents(el);var s=window.getSelection();s.removeAllRanges();s.addRange(r);document.dispatchEvent(new Event('selectionchange'));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));document.dispatchEvent(new Event('selectionchange'));return s.toString()})()")
Sys.sleep(0.8)
ok(is.character(sel)&&grepl("GOT\\[hello\\]",sel), sprintf("selected assistant text (%s)", substr(gsub("\n"," ",sel%||%""),1,24)))
tb<-ev("(function(){var t=document.querySelector('.aui-selection-toolbar');return t?'YES':'NO'})()")
ok(identical(tb,"YES"), "SelectionToolbar appeared over selection")

# 3) 点 Quote → composer 出现引用预览
ev("(function(){var q=document.querySelector('.aui-selection-toolbar-quote');if(q){q.click();return true}return false})()"); Sys.sleep(0.6)
cq<-ev("(function(){var e=document.querySelector('.aui-composer-quote');return e?e.innerText:''})()")
ok(is.character(cq)&&grepl("GOT\\[hello\\]",cq), sprintf("ComposerQuotePreview shows quote (%s)", substr(gsub("\n"," ",cq%||%""),1,24)))

# 4) 打后续问题 + 发送 → R 端应收到前置了 blockquote 的消息 → echo 回读
type("explain"); key(); r2<-waitReply(r1)
ok(grepl("> GOT\\[hello\\]",r2) && grepl("explain",r2),
   sprintf("R received quote as blockquote + text (%s)", substr(gsub("\n"," ",r2),1,48)))

# 5) 引用发送后 composer 引用预览清空(runtime 自动清 quote)
Sys.sleep(0.4)
gone<-ev("(function(){return document.querySelector('.aui-composer-quote')?'STILL':'GONE'})()")
ok(identical(gone,"GONE"), "quote cleared from composer after send")

ok(length(errs)==0, sprintf("no console errors (%d)", length(errs)))
if(length(errs)) cat("  ERRORS:\n   ", paste(head(errs,5),collapse="\n    "),"\n")
b$close(); p$kill()
cat(if(PASS)"QUOTE_VERIFY_PASS\n" else "QUOTE_VERIFY_FAIL\n")
