#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
devtools::load_all("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI", quiet = TRUE)
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"

# app → (var, 期望 hex 或 NA=base 默认)
cases <- list(
  list(app="16_style_chatgpt.R",    var="--aui-primary",    hex="#10a37f"),
  list(app="17_style_claude.R",     var="--aui-primary",    hex="#d97757"),
  list(app="18_style_grok.R",       var="--aui-background", hex="#0a0a0a"),
  list(app="19_style_gemini.R",     var="--aui-primary",    hex="#1a73e8"),
  list(app="20_style_perplexity.R", var="--aui-primary",    hex="#20808d")
)

port <- 8980; npass <- 0
for (c in cases) {
  expect <- shinyAssistantUI:::.color_to_hsl_components(c$hex)
  proc <- callr::r_bg(function(proj, app, port) {
    setwd(proj); suppressMessages(library(shiny))
    shiny::runApp(file.path("examples", app), host="127.0.0.1", port=port, launch.browser=FALSE)
  }, args=list(proj=PROJ, app=c$app, port=port), stdout=sprintf("/tmp/st_%s.log",c$app), stderr=sprintf("/tmp/st_%s.err",c$app))
  Sys.sleep(8)
  ok <- FALSE; got <- "(dead)"
  if (proc$is_alive()) {
    b <- tryCatch({ s<-ChromoteSession$new(); s$Page$navigate(sprintf("http://127.0.0.1:%d/",port)); s$Page$loadEventFired(); Sys.sleep(4); s }, error=function(e) NULL)
    if (!is.null(b)) {
      got <- b$Runtime$evaluate(sprintf("getComputedStyle(document.getElementById('chat')).getPropertyValue('%s').trim()", c$var))$result$value
      ok <- identical(got, expect)
      try(b$close(), silent=TRUE)
    }
  }
  cat(sprintf("[%s] %-24s %s: got='%s' expect='%s'\n", if(ok)"PASS" else "FAIL", c$app, c$var, got, expect))
  if (ok) npass <- npass + 1
  try(proc$kill(), silent=TRUE); Sys.sleep(1); port <- port + 1
}
cat(sprintf("\nstyle palettes: %d/%d applied correctly\n", npass, length(cases)))
system("rm -f /tmp/st_*.log /tmp/st_*.err")
