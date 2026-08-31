# Plan 51 A — codeagent client prewarm: UI remains interactive and reports warming.
suppressMessages({ library(chromote); library(callr) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT <- 9879L
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %s%s\n", if (ok) "PASS" else "FAIL", name,
              if (nzchar(detail)) paste0(": ", detail) else ""))
  if (!ok) failures <<- c(failures, name)
}
p <- callr::r_bg(function(proj, port) {
  setwd(proj)
  Sys.setenv(CODEAGENT_DEMO_PROFILE = "workbench")
  suppressMessages(library(shiny))
  shiny::runApp("examples/27_codeagent_backend.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT), stdout = "/tmp/wu.o", stderr = "/tmp/wu.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE)
Sys.sleep(12)
if (!p$is_alive()) {
  cat("BOOT FAIL\n")
  cat(tail(readLines("/tmp/wu.e", warn = FALSE), 15), sep = "\n")
  quit(status = 1)
}
errs <- character()
b <- chromote::ChromoteSession$new()
on.exit(try(b$close(), silent = TRUE), add = TRUE)
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_ = function(m) {
  if (identical(m$type, "error")) {
    errs <<- c(errs, paste(vapply(m$args, function(a) a$value %||% a$description %||% "",
                                 character(1)), collapse = " "))
  }
})
b$Runtime$exceptionThrown(callback_ = function(m) errs <<- c(errs, "Runtime.exceptionThrown"))
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
t0 <- Sys.time()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
b$Page$loadEventFired()
composer_t <- NA_real_
for (i in seq_len(40)) {
  Sys.sleep(0.25)
  if (isTRUE(ev("!!document.querySelector('[contenteditable=true]')"))) {
    composer_t <- as.numeric(Sys.time() - t0)
    break
  }
}
check("composer interactive fast (<4s)", !is.na(composer_t) && composer_t < 4,
      sprintf("%.1fs", composer_t))
welcome <- ev("document.querySelector('.aui-thread-welcome-root')?.innerText||''") %||% ""
check("workbench welcome message shown", grepl("Workbench profile is active", welcome, fixed = TRUE),
      substr(gsub("\n", " ", welcome), 1, 90))
warmed_seen <- FALSE
wtxt <- ""
for (i in seq_len(24)) {
  wt <- ev("document.querySelector('[data-slot=aui_warming]')?.innerText||''") %||% ""
  if (nzchar(wt)) {
    warmed_seen <- TRUE
    wtxt <- wt
    break
  }
  Sys.sleep(0.25)
}
check("warming indicator is codeagent-specific",
      warmed_seen && grepl("codeagent", wtxt) && !grepl("Claude Code", wtxt),
      trimws(gsub("\n", " ", wtxt)))
for (i in seq_len(40)) {
  if (!isTRUE(ev("!!document.querySelector('[data-slot=aui_warming]')"))) break
  Sys.sleep(0.5)
}
check("no console errors or exceptions", length(errs) == 0L, paste(errs, collapse = " | "))
b$close()
p$kill()
unlink(c("/tmp/wu.o", "/tmp/wu.e"))
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CODEAGENT_WARMUP_DONE\n")
