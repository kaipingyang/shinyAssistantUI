suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; port <- 9477L
unlink(c("/tmp/aui-dny.out","/tmp/aui-dny.err","/tmp/deny_probe.txt"))
fail<-character(); chk<-function(n,c,d=""){ok<-isTRUE(c);cat(sprintf("[%s] %-54s %s\n",if(ok)"PASS"else"FAIL",n,d));if(!ok)fail<<-c(fail,n)}
app<-callr::r_bg(function(project,port){setwd(project);Sys.setenv(AUI_PORT=port);suppressPackageStartupMessages(library(shiny));shiny::runApp("tests/verify/claude_deny_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(project=project,port=port),stdout="/tmp/aui-dny.out",stderr="/tmp/aui-dny.err")
on.exit(try(app$kill(),silent=TRUE),add=TRUE)
for(i in 1:120){if(!app$is_alive())break;if(file.exists("/tmp/aui-dny.err")&&any(grepl("Listening on",readLines("/tmp/aui-dny.err",warn=FALSE))))break;Sys.sleep(0.25)}
if(!app$is_alive()){cat(tail(readLines("/tmp/aui-dny.err",warn=FALSE),20),sep="\n");stop("boot failed")}
chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),"--disable-dev-shm-usage","--no-sandbox","--disable-gpu")))
b<-ChromoteSession$new(width=780,height=920);on.exit({try(b$close(),silent=TRUE);try(b$parent$get_browser()$get_process()$kill(),silent=TRUE)},add=TRUE)
cerr<-character();b$Runtime$enable();b$Runtime$consoleAPICalled(callback_=function(m)if(identical(m$type,"error"))cerr<<-c(cerr,"e"));b$Runtime$exceptionThrown(callback_=function(m)cerr<<-c(cerr,"x"))
val<-function(s){r<-b$Runtime$evaluate(s,returnByValue=TRUE);if(!is.null(r$exceptionDetails))stop(r$exceptionDetails$text);r$result$value}
waitf<-function(s,t=60,i=0.15){d<-Sys.time()+t;repeat{if(isTRUE(tryCatch(val(s),error=function(e)FALSE)))return(TRUE);if(Sys.time()>=d)return(FALSE);Sys.sleep(i)}}
clickxy<-function(sel){j<-val(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()",jsonlite::toJSON(sel,auto_unbox=TRUE)));if(is.null(j))return(FALSE);p<-fromJSON(j);b$Input$dispatchMouseEvent(type="mousePressed",x=p$x,y=p$y,button="left",clickCount=1L);b$Input$dispatchMouseEvent(type="mouseReleased",x=p$x,y=p$y,button="left",clickCount=1L);TRUE}
# 点击文本恰为 "Deny" 的按钮(不是 "Deny & tell Claude…")
click_deny<-function(){val("(function(){const bs=Array.from(document.querySelectorAll('.aui-shiny-approval button'));const d=bs.find(x=>x.textContent.trim()==='Deny');if(!d)return false;d.click();return true})()")}
napprovals<-function()val("document.querySelectorAll('.aui-shiny-approval').length")
b$Page$navigate(sprintf("http://127.0.0.1:%d/",port));b$Page$loadEventFired();waitf("!!document.querySelector('.aui-root')",20)
clickxy(".aui-lexical-input[contenteditable='true']");Sys.sleep(0.4)
b$Input$insertText(text="Create a file at /tmp/deny_probe.txt containing HELLO using the Write tool.");Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
chk("approval card appears (Deny button)", waitf("Array.from(document.querySelectorAll('.aui-shiny-approval button')).some(x=>x.textContent.trim()==='Deny')",60))
n1 <- napprovals(); cat("approval cards before deny:", n1, "\n")
chk("clicked plain Deny", isTRUE(click_deny()))
# 拒绝后:应出现 ✕ Denied,且【不再】弹新的待审批卡(interrupt=TRUE → agent 停机,不重问)
chk("denied indicator shows", waitf("!!document.querySelector('[data-approval-result=\"denied\"]')",15))
Sys.sleep(14)  # 给"跑飞/重问"留出时间窗
n2 <- napprovals(); cat("approval cards after deny+14s:", n2, "\n")
chk("no NEW approval card (agent stopped, no re-ask loop)", n2 <= n1, sprintf("before=%d after=%d", n1, n2))
chk("no pending Deny button lingering", isTRUE(!val("Array.from(document.querySelectorAll('.aui-shiny-approval button')).some(x=>x.textContent.trim()==='Deny')")))
chk("file NOT created (deny honored)", isTRUE(!file.exists("/tmp/deny_probe.txt")))
chk("no console errors", length(cerr)==0, if(length(cerr))"ERR" else "0")
try(b$close(),silent=TRUE);try(app$kill(),silent=TRUE); unlink("/tmp/deny_probe.txt")
if(length(fail))stop("FAILED: ",paste(fail,collapse=", "))
cat("DENY_VERIFY_DONE\n")
