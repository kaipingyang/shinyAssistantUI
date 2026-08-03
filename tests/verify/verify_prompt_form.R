# Plan 47 B 无头验证:PromptUser 表单 → 选 ANOVA + 提交 → decision$updatedInput 往返(installed 包)。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9847L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/prompt_form_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/pf.o",stderr="/tmp/pf.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/pf.e"),8),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="go")
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
for(i in 1:25){Sys.sleep(0.5); if(isTRUE(ev("!!document.querySelector('[data-slot=prompt-form]')"))) break}
has_form <- isTRUE(ev("!!document.querySelector('[data-slot=prompt-form]')"))
cat(sprintf("[%s] PromptUser form rendered (radio+slider)\n", if(has_form && isTRUE(ev("!!document.querySelector('[data-prompt-field=test]') && !!document.querySelector('[data-field=alpha]')")))"PASS" else "FAIL"))
# 选 ANOVA 单选 + 提交
ev("(function(){var ls=[].slice.call(document.querySelectorAll('[data-prompt-field=test] label'));var l=ls.find(function(x){return /ANOVA/.test(x.textContent)});if(l){l.querySelector('input').click();return true}return false})()");Sys.sleep(0.3)
ev("(function(){var s=document.querySelector('[data-prompt-submit]');if(s){s.click();return true}return false})()")
for(i in 1:20){Sys.sleep(0.4); d<-ev("document.querySelector('#decision')?.innerText||''"); if(!identical(d,"") && !identical(d,"none")) break}
dec <- ev("document.querySelector('#decision')?.innerText||''") %||% ""
cat("decision output:", gsub("\n"," ",substr(dec,1,120)), "\n")
cat(sprintf("[%s] updated_input round-trip: test=ANOVA in decision\n", if(grepl("ANOVA",dec) && grepl("test",dec))"PASS" else "FAIL"))
cat(sprintf("[%s] alpha default (0.05) carried\n", if(grepl("alpha",dec) && grepl("0.05",dec))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close();p$kill();system("rm -f /tmp/pf.*")
cat("PROMPT_FORM_VERIFY_DONE\n")
