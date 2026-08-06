# Plan 56 e2e (headless, REAL claude): drop a PDF into the composer → FileAttachmentAdapter
# base64s it → make_claude_handler sends it as a native document block → Claude reads the PDF
# and replies with the embedded token. Proves the full PDF-upload path end-to-end (no hang).
suppressMessages({library(chromote); library(callr); library(base64enc)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9938L
TOKEN <- "MANGO7X9Q"

# 造带 token 的小 PDF + base64
pf <- tempfile(fileext=".pdf")
pdf(pf, width=8, height=3); par(mar=c(0,0,0,0)); plot.new(); text(0.5,0.5,TOKEN,cex=1.6); dev.off()
b64 <- base64enc::base64encode(pf); unlink(pf)

p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/claude_backend_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/vp.o",stderr="/tmp/vp.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/vp.*")},add=TRUE); Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/vp.e"),20),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(){b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
lastReply<-function()ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
PASS<-TRUE; ok<-function(cond,label){cat(sprintf("[%s] %s\n",if(isTRUE(cond))"PASS" else {PASS<<-FALSE;"FAIL"},label))}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(5)

# 拖 PDF File 进 composer
mk<-sprintf("(function(){var b64='%s';var bin=atob(b64);var a=new Uint8Array(bin.length);for(var i=0;i<bin.length;i++)a[i]=bin.charCodeAt(i);return new File([a],'doc.pdf',{type:'application/pdf'})})()", b64)
ev(sprintf("(function(){var f=%s;var dt=new DataTransfer();dt.items.add(f);var ed=document.querySelector('[contenteditable=true]');['dragenter','dragover','drop'].forEach(function(t){ed.dispatchEvent(new DragEvent(t,{dataTransfer:dt,bubbles:true,cancelable:true}))});return true})()", mk))
Sys.sleep(1.2)
cnt<-ev("(function(){return document.querySelectorAll('.aui-attachment-root').length})()")
ok(is.numeric(cnt)&&cnt>=1, sprintf("PDF attached to composer (tiles=%s)", cnt))

ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()"); Sys.sleep(0.2)
b$Input$insertText(text="A PDF is attached. Reply with ONLY the exact token text shown in it."); Sys.sleep(0.2); key()
# 真 LLM:等到回复含 token 或超时
reply<-""; for(i in 1:120){Sys.sleep(0.5); reply<-lastReply(); if(grepl(TOKEN,reply,fixed=TRUE)) break}
ok(grepl(TOKEN,reply,fixed=TRUE), sprintf("Claude read the PDF token (%s)", substr(gsub("\n"," ",reply),1,60)))
ok(length(errs)==0, sprintf("no console errors (%d)", length(errs)))
if(length(errs)) cat("  ERR:\n   ", paste(head(errs,4),collapse="\n    "),"\n")
b$close(); p$kill()
cat(if(PASS)"PDF_VERIFY_PASS\n" else "PDF_VERIFY_FAIL\n")
