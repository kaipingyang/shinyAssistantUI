#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- 8961
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("examples/08_theming.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/thnav.log", stderr="/tmp/thnav.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(8)
if (!proc$is_alive()) { cat(readLines("/tmp/thnav.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) b$Runtime$evaluate(js)$result$value
chk <- function(n,c,d="") cat(sprintf("[%s] %-24s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))

# tab1 (Brand blue) 默认激活
Sys.sleep(1)
p1 <- ev("(function(){var e=document.getElementById('chat_blue');return e?getComputedStyle(e).getPropertyValue('--aui-primary').trim():'NONE'})()")
chk("tab1_blue_mounted_themed", grepl("^221 ", p1), p1)

# 点 tab2 (Warm)
ev("(function(){var t=Array.from(document.querySelectorAll('a.nav-link,button.nav-link,[data-bs-toggle=tab]')).find(a=>/Warm/.test(a.textContent));if(t)t.click();return !!t})()")
Sys.sleep(2.5)
p2 <- ev("(function(){var e=document.getElementById('chat_warm');return e?getComputedStyle(e).getPropertyValue('--aui-radius').trim():'NONE'})()")
chk("tab2_warm_mounted_radius", identical(p2, "1.25rem"), p2)

# 点 tab3 (Dark mode)
ev("(function(){var t=Array.from(document.querySelectorAll('a.nav-link,button.nav-link,[data-bs-toggle=tab]')).find(a=>/Dark/.test(a.textContent));if(t)t.click();return !!t})()")
Sys.sleep(2.5)
dk <- ev("(function(){var e=document.getElementById('chat_dark');return e?e.classList.contains('dark'):false})()")
chk("tab3_dark_class", isTRUE(dk), "")

b$close(); proc$kill()
cat("DONE\n")
