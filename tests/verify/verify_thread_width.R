suppressPackageStartupMessages({ library(callr); library(chromote) })
`%||%` <- function(x, y) if (is.null(x)) y else x
proj <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-48s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}

boot <- function(port, tmw, tag) {
  o <- sprintf("/tmp/tw-%s.out", tag); e <- sprintf("/tmp/tw-%s.err", tag); unlink(c(o, e))
  app <- callr::r_bg(function(proj, port, tmw) {
    setwd(proj); suppressPackageStartupMessages({ library(shiny); library(shinyAssistantUI) })
    handler <- function(message, on_chunk, on_done, ...) { on_chunk("hi"); on_done() }
    ui <- assistantUIPage(assistantUIOutput("chat", height = "100%"))
    server <- function(input, output, session)
      assistantUIServer("chat", handler = handler,
                        thread_max_width = if (nzchar(tmw)) tmw else NULL)
    shiny::runApp(shiny::shinyApp(ui, server), host = "127.0.0.1", port = port,
                  launch.browser = FALSE)
  }, args = list(proj = proj, port = port, tmw = tmw), stdout = o, stderr = e)
  for (i in 1:120) { if (!app$is_alive()) break
    if (file.exists(e) && any(grepl("Listening on", readLines(e, warn = FALSE)))) break
    Sys.sleep(0.25) }
  if (!app$is_alive()) { cat(tail(readLines(e, warn = FALSE), 15), sep = "\n"); stop("boot failed: ", tag) }
  app
}

measure <- function(port) {
  b <- ChromoteSession$new(width = 1200, height = 800)
  on.exit({ try(b$close(), silent = TRUE) }, add = TRUE)
  errs <- character(); b$Runtime$enable()
  b$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) errs <<- c(errs, "e"))
  b$Runtime$exceptionThrown(callback_ = function(m) errs <<- c(errs, "x"))
  val <- function(s) { r <- b$Runtime$evaluate(s, returnByValue = TRUE)
    if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
  wait <- function(s, t = 15) { d <- Sys.time() + t
    repeat { if (isTRUE(tryCatch(val(s), error = function(e) FALSE))) return(TRUE)
      if (Sys.time() >= d) return(FALSE); Sys.sleep(0.1) } }
  b$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); b$Page$loadEventFired(); Sys.sleep(1)
  ok <- wait("!!document.querySelector('[data-slot=aui_composer-shell]')", 15)
  w <- if (ok) val("document.querySelector('[data-slot=aui_composer-shell]').getBoundingClientRect().width") else NA
  list(mounted = ok, width = w, errs = length(errs))
}

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))

a1 <- boot(9301L, "", "full"); on.exit(try(a1$kill(), silent = TRUE), add = TRUE)
r1 <- measure(9301L); try(a1$kill(), silent = TRUE)
chk("default: widget mounted", r1$mounted)
chk("default: content is FULL width (>900px at 1200 viewport)", isTRUE(r1$width > 900),
    sprintf("width=%.0f", r1$width %||% NA))
chk("default: 0 console errors", r1$errs == 0)

a2 <- boot(9302L, "44rem", "cap"); on.exit(try(a2$kill(), silent = TRUE), add = TRUE)
r2 <- measure(9302L); try(a2$kill(), silent = TRUE)
chk("capped: widget mounted", r2$mounted)
chk("capped: content limited to ~44rem/704px (<= 740px)", isTRUE(r2$width <= 740),
    sprintf("width=%.0f", r2$width %||% NA))
chk("capped: 0 console errors", r2$errs == 0)

if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("THREAD_WIDTH_VERIFY_DONE\n")
