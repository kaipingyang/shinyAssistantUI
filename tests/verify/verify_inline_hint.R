# Verify the SAFE inline argument-hint ghost:
#  1) select /greet -> root gets data-cmd-bare + chip ::after shows "[name]"
#  2) type " world" -> data-cmd-bare cleared -> ghost gone
#  3) Enter submits "/greet world" cleanly (handler receives it) -> the critical
#     regression the previous (real-span) version broke.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9886L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/skill_hint_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/gh.o",stderr="/tmp/gh.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/gh.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/gh.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value%||%""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
key<-function(k,code,vk){b$Input$dispatchKeyEvent(type="keyDown",key=k,code=code,windowsVirtualKeyCode=vk);b$Input$dispatchKeyEvent(type="keyUp",key=k,code=code,windowsVirtualKeyCode=vk)}
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.3)

# select /greet from menu -> chip
b$Input$insertText(text="/greet"); Sys.sleep(1); key("Tab","Tab",9L); Sys.sleep(1.2)
after_content <- ev("(function(){var c=document.querySelector('.aui-directive-chip');if(!c)return'(no chip)';return getComputedStyle(c,'::after').content})()") %||% ""
bare_attr <- ev("(function(){var e=document.querySelector('.aui-lexical-input');return e?e.getAttribute('data-cmd-bare'):null})()") %||% ""
cat("bare command -> data-cmd-bare:", bare_attr, " chip ::after content:", after_content, "\n")
cat(sprintf("[%s] ghost hint shows after selecting a command\n", if(grepl("name", after_content))"PASS" else "FAIL"))

# type an argument -> ghost should vanish
b$Input$insertText(text=" world"); Sys.sleep(0.8)
after2 <- ev("(function(){var c=document.querySelector('.aui-directive-chip');if(!c)return'(no chip)';return getComputedStyle(c,'::after').content})()") %||% ""
bare2 <- ev("(function(){var e=document.querySelector('.aui-lexical-input');return e?e.getAttribute('data-cmd-bare'):null})()") %||% ""
cat("after typing arg -> data-cmd-bare:", bare2, " ::after content:", after2, "\n")
cat(sprintf("[%s] ghost hint disappears once an argument is typed\n", if(!grepl("name", after2))"PASS" else "FAIL"))

# CRITICAL: Enter must submit clean "/greet world"
editor_txt <- ev("(function(){var t=document.querySelector('[contenteditable=true]');return t?t.innerText:''})()") %||% ""
key("Enter","Enter",13L); Sys.sleep(2)
reply <- ev("(function(){var a=document.querySelectorAll('[data-role=assistant]');return a.length?a[a.length-1].innerText:''})()") %||% ""
cat("editor text:", editor_txt, " | reply:", reply, "\n")
cat(sprintf("[%s] Enter submits clean '/greet world' (handler received GOT[/greet world])\n", if(grepl("GOT\\[/greet world\\]", reply))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "),"\n")
b$close(); p$kill()
cat("GHOST_HINT_DONE\n")
