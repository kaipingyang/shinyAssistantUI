# Regression (user-reported): selecting a slash command then typing an argument WITHOUT
# a leading space must yield "/cmd arg" (space between) and Enter must submit it.
# Before the fix: completion left "/cmd" with no trailing space -> "/cmdarg" (one token)
# -> never sent. Fix: TrailingSpacePlugin appends a space on the chip's "created"
# mutation + moves the caret after it.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9895L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/skill_hint_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/ss.o",stderr="/tmp/ss.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/ss.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/ss.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(k,code,vk){b$Input$dispatchKeyEvent(type="keyDown",key=k,code=code,windowsVirtualKeyCode=vk);b$Input$dispatchKeyEvent(type="keyUp",key=k,code=code,windowsVirtualKeyCode=vk)}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)
ev("(function(){document.querySelector('[contenteditable=true]').focus();return true})()"); Sys.sleep(0.3)
b$Input$insertText(text="/greet"); Sys.sleep(1); key("Tab","Tab",9L); Sys.sleep(1)
t1 <- ev("(function(){return document.querySelector('[contenteditable=true]').innerText})()") %||% ""
cat(sprintf("[%s] completion adds a trailing space after the chip\n", if(grepl(" $", t1))"PASS" else "FAIL"))
b$Input$insertText(text="hello"); Sys.sleep(0.6)   # user types WITHOUT a leading space
t2 <- ev("(function(){return document.querySelector('[contenteditable=true]').innerText})()") %||% ""
cat(sprintf("[%s] typing an arg yields '/greet hello' (space preserved), not '/greethello'\n", if(grepl("greet hello", t2) && !grepl("greethello", t2))"PASS" else "FAIL"))
key("Enter","Enter",13L); Sys.sleep(2)
reply <- ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:'(none)'})()") %||% ""
cleared <- ev("(function(){return document.querySelector('[contenteditable=true]').innerText.trim().length===0})()") %||% NA
cat("editor:", t2, " | reply:", reply, "\n")
cat(sprintf("[%s] Enter submits and clears the composer (handler got GOT[/greet hello])\n", if(grepl("GOT\\[/greet hello\\]", reply) && isTRUE(cleared))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close(); p$kill()
cat("SLASH_SUBMIT_DONE\n")
