#!/usr/bin/env Rscript
suppressMessages({library(chromote);library(callr)})
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
run<-function(app,port,drive){
  p<-callr::r_bg(function(proj,app,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp(file.path("tests/verify",app),host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,app=app,port=port),stdout=paste0("/tmp/",app,".log"),stderr=paste0("/tmp/",app,".err"))
  on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(9)
  if(!p$is_alive()){cat("BOOT FAIL",app,"\n");cat(tail(readLines(paste0("/tmp/",app,".err")),5),sep="\n");return()}
  b<-chromote::ChromoteSession$new();b$Page$navigate(sprintf("http://127.0.0.1:%d/",port));b$Page$loadEventFired();Sys.sleep(4)
  ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
  drive(b,ev)
  b$close();p$kill();system(paste0("rm -f /tmp/",app,".log /tmp/",app,".err"))
}
send<-function(b,ev,txt){ev("(function(){var t=document.querySelector('textarea');t.focus();return !!t})()");Sys.sleep(0.4);b$Input$insertText(text=txt);Sys.sleep(0.4);b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)}
chk<-function(n,c,d="")cat(sprintf("[%s] %-26s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))

cat("### 审批流(新栈)###\n")
run("approval_app.R",9001,function(b,ev){
  send(b,ev,"delete the file");Sys.sleep(3)
  chk("tool_card_shown", grepl("delete_file",ev("document.body.innerText")),"")
  approve<-ev("(function(){var bs=Array.from(document.querySelectorAll('button'));var t=bs.find(b=>/^\\s*Approve\\s*$/.test(b.innerText));if(t){t.click();return true}return false})()")
  chk("approve_clicked",isTRUE(approve),"")
  Sys.sleep(3)
  chk("approved_and_replied", grepl("Deletion approved|Approved",ev("document.body.innerText")),"")
})

cat("### Artifacts(新栈)###\n")
run("artifacts_app.R",9002,function(b,ev){
  send(b,ev,"draft a plan");Sys.sleep(3)
  chk("artifact_panel", isTRUE(ev("!!document.querySelector('.aui-artifact-panel')")),"")
  chk("artifact_title", identical(ev("(function(){var t=document.querySelector('.aui-artifact-title');return t?t.innerText:''})()"),"Project Plan"),"")
  chk("artifact_content", grepl("Phase|Deadline",ev("(function(){var p=document.querySelector('.aui-artifact-panel');return p?p.innerText:''})()")),"")
})
cat("DONE\n")
