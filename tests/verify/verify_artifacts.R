#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8995
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/artifacts_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/af.log", stderr="/tmp/af.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9); if (!proc$is_alive()) { cat(readLines("/tmp/af.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-24s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
ev("document.querySelector('[contenteditable=true]').focus()"); Sys.sleep(0.5)
b$Input$insertText(text = "draft a plan")
Sys.sleep(0.5)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
Sys.sleep(3)
chk("artifact_panel_opened", isTRUE(ev("!!document.querySelector('.aui-artifact-panel')")), "")
title <- ev("(function(){var t=document.querySelector('.aui-artifact-title');return t?t.innerText:'(none)'})()")
chk("artifact_title", identical(title, "Project Plan"), title)
body_has <- ev("(function(){var p=document.querySelector('.aui-artifact-panel');return p?/Phase 1|Deadline/.test(p.innerText):false})()")
chk("artifact_content_rendered", isTRUE(body_has), "")
# 点关闭
ev("(function(){var b=document.querySelector('.aui-artifact-close');if(b){b.click();return true}return false})()")
Sys.sleep(1)
chk("artifact_panel_closed", !isTRUE(ev("!!document.querySelector('.aui-artifact-panel')")), "")
b$close(); proc$kill(); system("rm -f /tmp/af.log /tmp/af.err")
cat("DONE\n")
