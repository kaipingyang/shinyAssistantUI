# Plan 52.B browser integration verify (Rule #1c): remote handler inside a REAL
# assistantUIServer app. Headless: send a file-creating prompt -> approval card
# renders in DOM -> in viewport -> click Approve -> tool executes (file appears).
# Asserts the MAIN app process never loaded curl/ellmer/codeagent + 0 console err.
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9871L
NSFILE <- "/tmp/sau_app_ns.txt"; PROOF <- "/tmp/sau_remote_proof_browser.txt"
file.remove(Filter(file.exists, c(NSFILE, PROOF)))

p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));
      shiny::runApp("tests/verify/codeagent_remote_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
      args=list(proj=PROJ,port=PORT),stdout="/tmp/rem.o",stderr="/tmp/rem.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/rem.*")},add=TRUE); Sys.sleep(16)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/rem.e"),20),sep="\n");quit(status=1)}

errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
b$Runtime$exceptionThrown(callback_=function(m) errs<<-c(errs, m$exceptionDetails$exception$description %||% "exception"))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(5)

ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
b$Input$insertText(text=sprintf("Use your tools to create a file at the absolute path '%s' whose exact contents are HELLO42. One tool call.", PROOF))
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)

appeared<-FALSE
for(i in 1:160){Sys.sleep(0.5); if(isTRUE(ev("!!document.querySelector('.aui-shiny-approval')"))){appeared<-TRUE;break}; if(!p$is_alive())break}
cat(sprintf("[%s] approval card rendered in the browser (remote handler)\n", if(appeared)"PASS" else "FAIL"))
inview<-ev("(function(){var e=document.querySelector('.aui-shiny-approval');if(!e)return false;var r=e.getBoundingClientRect();return r.height>0&&r.top>=0&&r.bottom<=(window.innerHeight+2)})()")
cat(sprintf("[%s] approval card in viewport\n", if(isTRUE(inview))"PASS" else "FAIL"))
clicked<-ev("(function(){var c=document.querySelector('.aui-shiny-approval');if(!c)return false;var x=[].slice.call(c.querySelectorAll('button')).find(function(y){return (y.innerText||'').trim()==='Approve'});if(x){x.click();return true}return false})()")
cat(sprintf("[%s] clicked Approve\n", if(isTRUE(clicked))"PASS" else "FAIL"))
made<-FALSE; for(i in 1:80){Sys.sleep(0.5); if(file.exists(PROOF)){made<-TRUE;break}; if(!p$is_alive())break}
cat(sprintf("[%s] approve -> worker executed the gated tool (file created)\n", if(made)"PASS" else "FAIL"))

ns <- if(file.exists(NSFILE)) readLines(NSFILE) else character(0)
curl_app <- "curl" %in% ns; ell_app <- "ellmer" %in% ns; ca_app <- "codeagent" %in% ns
cat(sprintf("[%s] APP process never loaded curl/ellmer/codeagent (ns probe: %d pkgs)\n", if(length(ns)>0 && !curl_app && !ell_app && !ca_app)"PASS" else "FAIL", length(ns)))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "),"\n")
if(curl_app||ell_app||ca_app) cat("  LEAKED into app:", paste(intersect(ns,c("curl","ellmer","codeagent")),collapse=","),"\n")
b$close(); p$kill(); file.remove(Filter(file.exists,c(PROOF)))
cat("REMOTE_BROWSER_DONE\n")
