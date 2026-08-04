# Plan A verify: typing "/" opens the slash menu and the command shows its
# argument hint ("/greet [name]"). No LLM/backend needed.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9877L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));
      shiny::runApp("tests/verify/skill_hint_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
      args=list(proj=PROJ,port=PORT),stdout="/tmp/sh.o",stderr="/tmp/sh.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/sh.*")},add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/sh.e"),15),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
b$Input$insertText(text="/")
Sys.sleep(1.5)
body <- ev("document.body.innerText") %||% ""
has_cmd  <- grepl("greet", body)
has_hint <- grepl("\\[name\\]", body)
cat("menu contains greet:", has_cmd, " contains [name]:", has_hint, "\n")
cat(sprintf("[%s] slash menu shows the command with its argument hint\n", if(has_cmd && has_hint)"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(!has_cmd||!has_hint) cat("  body snippet:", substr(gsub("\n"," ",body),1,220), "\n")
b$close(); p$kill()
cat("SKILL_HINT_DONE\n")
