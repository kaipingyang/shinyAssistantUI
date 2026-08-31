# Plan 56 e2e (headless): drop an .xlsx into the composer → FileAttachmentAdapter base64s it
# → R .attachment_text_sections runs readxl → markdown table → echoed. Asserts the reply
# contains the sheet's real cell data. No LLM (echo fixture) → deterministic.
suppressMessages({library(chromote); library(callr); library(writexl); library(base64enc)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9937L

# 造 xlsx(已知数据)+ base64
tf <- tempfile(fileext=".xlsx")
writexl::write_xlsx(list(Data=data.frame(name=c("Alice","Bob"), score=c(91L,88L))), tf)
b64 <- base64enc::base64encode(tf); unlink(tf)
XLSX_MIME <- "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/xlsx_echo_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/vx.o",stderr="/tmp/vx.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/vx.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/vx.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
b$Runtime$exceptionThrown(callback_=function(m) errs<<-c(errs,paste0("EXCEPTION: ",m$exceptionDetails$text%||%"unknown")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(){b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
lastReply<-function()ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
waitReply<-function(){for(i in 1:60){Sys.sleep(0.25);r<-lastReply();if(grepl('GOT\\[',r))return(r)};lastReply()}
PASS<-TRUE; ok<-function(cond,label){cat(sprintf("[%s] %s\n",if(isTRUE(cond))"PASS" else {PASS<<-FALSE;"FAIL"},label))}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)

# 拖 xlsx File 进 composer(File 由 base64 构造)
mk<-sprintf("(function(){var b64='%s';var bin=atob(b64);var a=new Uint8Array(bin.length);for(var i=0;i<bin.length;i++)a[i]=bin.charCodeAt(i);return new File([a],'grades.xlsx',{type:'%s'})})()", b64, XLSX_MIME)
attached<-ev(sprintf("(function(){var f=%s;var dt=new DataTransfer();dt.items.add(f);var ed=document.querySelector('[contenteditable=true]');['dragenter','dragover','drop'].forEach(function(t){ed.dispatchEvent(new DragEvent(t,{dataTransfer:dt,bubbles:true,cancelable:true}))});return true})()", mk))
Sys.sleep(1.2)
cnt<-ev("(function(){return document.querySelectorAll('.aui-attachment-root').length})()")
ok(is.numeric(cnt)&&cnt>=1, sprintf("xlsx attached to composer (tiles=%s)", cnt))

# 发送(text 可空;send() 时 base64 读文件)
ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()"); Sys.sleep(0.2)
b$Input$insertText(text="summarize"); Sys.sleep(0.2); key()
r<-waitReply()
ok(grepl("Sheet: Data",r,fixed=TRUE), "reply contains sheet header (Sheet: Data)")
ok(grepl("Alice",r,fixed=TRUE) && grepl("91",r,fixed=TRUE), "reply contains real cell data (Alice, 91)")
ok(grepl("name",r,fixed=TRUE) && grepl("score",r,fixed=TRUE), "reply contains column headers (name, score; markdown table rendered)")
ok(length(errs)==0, sprintf("no console errors (%d)", length(errs)))
if(length(errs)) cat("  ERR:\n   ", paste(head(errs,4),collapse="\n    "),"\n")
b$close(); p$kill()
cat(if(PASS)"EXCEL_VERIFY_PASS\n" else "EXCEL_VERIFY_FAIL\n")
