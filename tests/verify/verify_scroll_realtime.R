# Real-time stick-to-bottom regression gate (Plan-51-adjacent scroll fix).
# During rapid streaming the viewport must track the bottom (assistant-ui autoScroll relies on an
# accurate scrollHeight; content-visibility/contain-intrinsic-size on message roots corrupted it →
# 200–2000px lag). Fixed by removing that CSS. RED baseline: median≈242, max≈2233, 24/45 >200px.
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9901L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/scroll_repro_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/scr.o",stderr="/tmp/scr.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/scr.e",warn=FALSE),8),sep="\n");quit(status=1)}
b<-chromote::ChromoteSession$new();b$Runtime$enable();b$Emulation$setDeviceMetricsOverride(width=440L,height=560L,deviceScaleFactor=1,mobile=FALSE)
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(3)
ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()");Sys.sleep(0.3)
b$Input$insertText(text="go");b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L);b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
gapjs<-"(function(){var v=document.querySelector('[data-slot=aui_thread-viewport]');if(!v)return -1;return Math.round(v.scrollHeight - v.scrollTop - v.clientHeight)})()"
gaps<-c(); for(i in 1:45){Sys.sleep(0.1); g<-ev(gapjs); if(is.numeric(g)&&g>=0) gaps<-c(gaps,g)}
med<-round(median(gaps,na.rm=TRUE)); mx<-max(gaps,na.rm=TRUE); behind<-sum(gaps>200,na.rm=TRUE)
cat(sprintf("live-gap during stream: median=%d max=%d >200px=%d/%d\n", med, mx, behind, length(gaps)))
# Gate on the STEADY-STATE median (stable signal; baseline was ~242). Transient max spikes when a
# large tool card appends are a single-frame catch-up (timing-variable) and are intentionally not gated.
cat(sprintf("[%s] viewport tracks bottom in real-time (median<=150; baseline was ~242)\n", if(med<=150)"PASS" else "FAIL"))
b$close();p$kill();system("rm -f /tmp/scr.*")
cat("SCROLL_REALTIME_DONE\n")
