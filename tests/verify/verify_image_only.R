# Regression (user-reported): an image-only message (empty text + attachment) must
# reach the handler. server.R previously dropped every empty-text submit, so an
# image-only first message was silently discarded (no cold-start, no reply). Uses
# the echo fixture (handler replies GOT[<message>]) — no LLM needed.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9927L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/attach_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/vio.o",stderr="/tmp/vio.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/vio.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/vio.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(){b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
lastReply<-function()ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
waitReply<-function(){for(i in 1:40){Sys.sleep(0.25);r<-lastReply();if(grepl('GOT\\[',r))return(r)};lastReply()}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)
ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()"); Sys.sleep(0.3)

# 1) truly-empty submit (no text, no attachment) -> dropped (no reply)
key(); Sys.sleep(1.5)
cat(sprintf("[%s] empty submit dropped (no assistant reply)\n", if(!grepl('GOT',lastReply()))"PASS" else "FAIL"))

# 2) image-only -> reaches handler (reply GOT[] since message text is empty)
mk<-"(function(){var c=document.createElement('canvas');c.width=16;c.height=16;var x=c.getContext('2d');x.fillStyle='#39f';x.fillRect(0,0,16,16);return new Promise(function(res){c.toBlob(function(bl){res(new File([bl],'b.png',{type:'image/png'}))},'image/png')})})()"
b$Runtime$evaluate(sprintf("(async function(){var f=await %s;var dt=new DataTransfer();dt.items.add(f);var ed=document.querySelector('[contenteditable=true]');['dragenter','dragover','drop'].forEach(function(t){ed.dispatchEvent(new DragEvent(t,{dataTransfer:dt,bubbles:true,cancelable:true}))});return true})()", mk), awaitPromise=TRUE); Sys.sleep(0.8)
key(); r2<-waitReply()
cat(sprintf("[%s] image-only reaches handler (reply=%s)\n", if(grepl('GOT\\[',r2))"PASS" else "FAIL", JSON<-substr(gsub('\n',' ',r2),1,20)))

# 3) text still works
ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()"); Sys.sleep(0.2)
b$Input$insertText(text="hello"); Sys.sleep(0.2); key(); r3<-waitReply()
cat(sprintf("[%s] text message reaches handler (GOT[hello])\n", if(grepl('GOT\\[hello\\]',r3))"PASS" else "FAIL"))

cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close(); p$kill()
cat("IMAGE_ONLY_VERIFY_DONE\n")
