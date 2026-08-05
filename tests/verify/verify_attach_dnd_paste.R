# Verify: paste an image (Ctrl+V) and drag-drop an image both add an attachment
# to the composer (.aui-attachment-root). Synthetic ClipboardEvent/DragEvent with
# a real File in a DataTransfer, dispatched on the editable (bubbles to dropzone).
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9879L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));
      shiny::runApp("tests/verify/attach_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
      args=list(proj=PROJ,port=PORT),stdout="/tmp/at.o",stderr="/tmp/at.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/at.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/at.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)

# helper JS: make a 1x1 png File
mkfile <- "(function(){var b64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';var bin=atob(b64);var a=new Uint8Array(bin.length);for(var i=0;i<bin.length;i++)a[i]=bin.charCodeAt(i);return new File([a],'shot.png',{type:'image/png'});})()"
count <- function() ev("document.querySelectorAll('.aui-attachment-root').length") %||% 0
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.3)
cat("attachments at start:", count(), "\n")

# --- PASTE ---
ev(sprintf("(function(){var f=%s;var dt=new DataTransfer();dt.items.add(f);var ed=document.querySelector('[contenteditable=true]');ed.focus();var e=new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true});ed.dispatchEvent(e);return true})()", mkfile))
paste_ok<-FALSE; for(i in 1:40){Sys.sleep(0.25); if(count()>=1){paste_ok<-TRUE;break}}
cat(sprintf("[%s] paste image -> attachment added (count=%d)\n", if(paste_ok)"PASS" else "FAIL", count()))

# --- DROP ---
before<-count()
ev(sprintf("(function(){var f=%s;var dt=new DataTransfer();dt.items.add(f);var ed=document.querySelector('[contenteditable=true]');['dragenter','dragover','drop'].forEach(function(t){ed.dispatchEvent(new DragEvent(t,{dataTransfer:dt,bubbles:true,cancelable:true}))});return true})()", mkfile))
drop_ok<-FALSE; for(i in 1:40){Sys.sleep(0.25); if(count()>before){drop_ok<-TRUE;break}}
cat(sprintf("[%s] drag-drop image -> attachment added (count=%d, was %d)\n", if(drop_ok)"PASS" else "FAIL", count(), before))

cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "),"\n")
b$close(); p$kill()
cat("ATTACH_DONE\n")
