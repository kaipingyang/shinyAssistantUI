#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(chromote)
  library(callr)
})
source("tests/verify/owned_process_cleanup.R")

main <- function() {
  project <- normalizePath(".")
  host <- Sys.getenv("AUI_THEME_HOST", "bslib")
  stopifnot(host %in% c("bslib", "standalone"))
  port <- httpuv::randomPort()
  stdout <- tempfile("theme-stdout-")
  stderr <- tempfile("theme-stderr-")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, c(stdout, stderr))
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(project, port, host) {
    setwd(project)
    Sys.setenv(AUI_THEME_HOST = host)
    library(shinyAssistantUI)
    installed <- normalizePath(find.package("shinyAssistantUI"))
    stopifnot(startsWith(installed, paste0(normalizePath(path.expand("~")), "/")))
    message("INSTALL=", installed, " VERSION=", packageVersion("shinyAssistantUI"))
    shiny::runApp("tests/verify/theme_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, port = port, host = host), stdout = stdout, stderr = stderr)
  ready <- FALSE
  for (i in seq_len(150L)) {
    if (!app$is_alive()) break
    ready <- any(grepl("Listening on", readLines(stderr, warn = FALSE), fixed = TRUE))
    if (ready) break
    Sys.sleep(0.1)
  }
  if (!ready) stop(paste(readLines(stderr, warn = FALSE), collapse = "\n"), call. = FALSE)
  cat(grep("INSTALL=", readLines(stderr, warn = FALSE), value = TRUE), "\n")
  cat("THEME_HOST=", host, "\n", sep = "")

  errors <- network_errors <- character()
  # Headless Chrome needs an explicit desktop pointer for (hover: hover).
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu",
    "--blink-settings=primaryHoverType=2,availableHoverTypes=2,primaryPointerType=4,availablePointerTypes=4"
  )))
  browser <- ChromoteSession$new(width = 1100, height = 1050)
  browser$Emulation$setDeviceMetricsOverride(
    width = 1100L, height = 1050L, deviceScaleFactor = 1, mobile = FALSE
  )
  browser$Emulation$setTouchEmulationEnabled(enabled = FALSE)
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- c(errors, "console.error")
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    network_errors <<- c(network_errors, event$errorText)
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- c(network_errors, event$response$url)
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  checks <- 0L
  failures <- character()
  check <- function(label, ok) {
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", label))
    if (!isTRUE(ok)) {
      cat("DOM_STATE ", value("JSON.stringify({roots:document.querySelectorAll('.aui-root').length,threads:document.querySelectorAll('.aui-thread-root').length,body:document.body.innerText.slice(-1500)})"), "\n", sep = "")
      cat(c(errors, network_errors, tail(readLines(stderr, warn = FALSE), 15L)), sep = "\n")
      failures <<- c(failures, label)
    }
    checks <<- checks + 1L
  }
  wait_for <- function(js) {
    deadline <- Sys.time() + 10
    repeat {
      if (isTRUE(value(js))) {
        return(TRUE)
      }
      if (!app$is_alive() || Sys.time() > deadline) {
        return(FALSE)
      }
      Sys.sleep(0.1)
    }
  }
  scheme <- function(name) {
    browser$Emulation$setEmulatedMedia(media = "screen", features = list(
      list(name = "prefers-color-scheme", value = name)
    ))
  }
  palette <- function() {
    value(
      "['chat_light','chat_dark','chat_auto'].map(id=>{const e=document.getElementById(id),r=e.querySelector('.aui-thread-root'),s=getComputedStyle(r);return {id,dark:e.classList.contains('dark'),background:s.backgroundColor,primary:getComputedStyle(e).getPropertyValue('--primary').trim(),radius:getComputedStyle(e).getPropertyValue('--radius').trim()}})"
    )
  }
  hover_rgba <- function(selector, property) {
    quoted <- as.character(jsonlite::toJSON(selector, auto_unbox = TRUE))
    value(sprintf("document.querySelector(%s).scrollIntoView({block:'center',behavior:'instant'});true", quoted))
    Sys.sleep(0.15)
    point <- value(sprintf("(()=>{const r=document.querySelector(%s).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", quoted))
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    Sys.sleep(0.3)
    measurement <- value(sprintf(
      "(()=>{const e=document.querySelector(%s),c=new OffscreenCanvas(1,1),x=c.getContext('2d'),css=getComputedStyle(e).%s;x.fillStyle=css;x.fillRect(0,0,1,1);return {css,hovered:e.matches(':hover'),canHover:matchMedia('(hover:hover)').matches,rgba:[...x.getImageData(0,0,1,1).data]}})()",
      quoted, property
    ))
    cat("HOVER_MEASUREMENT ", jsonlite::toJSON(measurement, auto_unbox = TRUE), "\n", sep = "")
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = 1000, y = 5)
    unlist(measurement$rgba, use.names = FALSE)
  }
  host_colors_unchanged <- function() {
    if (host == "standalone") {
      return(isTRUE(value(
        "(()=>{const c=new OffscreenCanvas(1,1),x=c.getContext('2d');const rgb=color=>{x.clearRect(0,0,1,1);x.fillStyle=color;x.fillRect(0,0,1,1);return [...x.getImageData(0,0,1,1).data].join(',')};const expected=rgb(getComputedStyle(document.body).getPropertyValue('--primary'));return rgb(getComputedStyle(document.getElementById('host_theme_background')).backgroundColor)===expected&&rgb(getComputedStyle(document.getElementById('host_theme_text')).color)===expected})()"
      )))
    }
    isTRUE(value(
      "(()=>{const rgb=getComputedStyle(document.body).getPropertyValue('--bs-primary-rgb').trim().split(',').map(Number),expected=`rgb(${rgb.join(', ')})`;return getComputedStyle(document.getElementById('host_theme_background')).backgroundColor===expected&&getComputedStyle(document.getElementById('host_theme_text')).color===expected})()"
    ))
  }
  scheme("light")
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("three installed theme widgets mount", wait_for("['chat_light','chat_dark','chat_auto'].every(id=>document.getElementById(id)?.querySelectorAll('.aui-thread-root').length===1)"))
  check("desktop mouse hover is available", isTRUE(value("matchMedia('(hover:hover)').matches")))
  initial <- palette()
  cat("INITIAL_PALETTES ", jsonlite::toJSON(initial, auto_unbox = TRUE), "\n", sep = "")
  check("light theme uses scoped CSS-ready tokens", isTRUE(value(
    "document.getElementById('chat_light').style.getPropertyValue('--primary')==='#2563eb'&&document.getElementById('chat_light').style.getPropertyValue('--background')==='#eff6ff'"
  )))
  check("custom background actually paints the light widget", identical(initial[[1L]]$background, "rgb(239, 246, 255)"))
  check("custom radius reaches the widget", identical(initial[[1L]]$radius, "1rem"))
  check(
    "fixed dark and auto-light palettes are isolated",
    !initial[[1L]]$dark && initial[[2L]]$dark && !initial[[3L]]$dark &&
      initial[[2L]]$background != initial[[3L]]$background &&
      initial[[1L]]$background != initial[[3L]]$background
  )
  check("host colors remain unchanged outside widgets", host_colors_unchanged())

  for (mode in c("light", "dark", "auto")) {
    id <- paste0("chat_", mode)
    check(paste(id, "real composer ready"), wait_for(sprintf(
      "!!document.querySelector('#%s .aui-lexical-input[contenteditable=true]')", id
    )))
    value(sprintf(
      "(()=>{const e=document.querySelector('#%s .aui-lexical-input');e.scrollIntoView({block:'center'});e.focus();return true})()", id
    ))
    browser$Input$insertText(text = paste(mode, "theme question"))
    if (mode == "light") {
      check("light Send button becomes enabled", wait_for("document.querySelector('#chat_light .aui-composer-send')?.disabled===false"))
      check("custom primary paints the enabled Send button", wait_for(
        "(()=>{const e=document.querySelector('#chat_light .aui-composer-send');return e&&!e.disabled&&getComputedStyle(e).backgroundColor==='rgb(37, 99, 235)'})()"
      ))
      rgba <- hover_rgba("#chat_light .aui-composer-send", "backgroundColor")
      cat("SEND_HOVER_RGBA ", paste(rgba, collapse = ","), "\n", sep = "")
      check(
        "Send hover retains the themed 80 percent alpha",
        length(rgba) == 4L && all(abs(rgba - c(37, 99, 235, 204)) <= 1)
      )
    }
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
    check(paste(id, "receives its own reply"), wait_for(sprintf(
      "document.getElementById('%s').innerText.includes('Theme reply: %s theme question')&&!document.querySelector('#%s .aui-composer-cancel')",
      id, mode, id
    )))
    if (mode == "light") {
      check("custom primary paints assistant links", wait_for(
        "(()=>{const e=document.querySelector('#chat_light [data-slot=aui_assistant-text] a');return !!e&&getComputedStyle(e).color==='rgb(37, 99, 235)'})()"
      ))
      rgba <- hover_rgba("#chat_light [data-slot=aui_assistant-text] a", "color")
      cat("LINK_HOVER_RGBA ", paste(rgba, collapse = ","), "\n", sep = "")
      check(
        "link hover retains the themed 80 percent alpha",
        length(rgba) == 4L && all(abs(rgba - c(37, 99, 235, 204)) <= 1)
      )
    }
    check(paste(id, "does not leak replies to another widget"), isTRUE(value(sprintf(
      "['chat_light','chat_dark','chat_auto'].filter(id=>id!=='%s').every(id=>!document.getElementById(id).innerText.includes('Theme reply: %s theme question'))",
      id, mode
    ))))
  }
  check("dark assistant text uses its foreground token", isTRUE(value(
    "(()=>{const e=document.querySelector('#chat_dark [data-slot=aui_assistant-text] p');return !!e&&getComputedStyle(e).color==='oklch(0.985 0 0)'})()"
  )))

  scheme("dark")
  check("auto mode follows a system dark change", wait_for("document.getElementById('chat_auto').classList.contains('dark')"))
  dark <- palette()
  check("auto dark paints the same palette as fixed dark", identical(dark[[2L]]$background, dark[[3L]]$background))
  check(
    "system dark does not alter the explicit light theme",
    !dark[[1L]]$dark && identical(dark[[1L]]$background, initial[[1L]]$background)
  )
  scheme("light")
  check("auto mode follows system light again", wait_for("!document.getElementById('chat_auto').classList.contains('dark')"))
  restored <- palette()
  check(
    "fixed dark remains dark and auto-light recovers its original colors",
    restored[[2L]]$dark && identical(restored[[2L]]$background, initial[[2L]]$background) &&
      identical(restored[[3L]]$background, initial[[3L]]$background)
  )
  check("system scheme changes leave host colors unchanged", host_colors_unchanged())

  browser$Page$reload()
  browser$Page$loadEventFired()
  for (mode in c("light", "dark", "auto")) {
    check(paste(mode, "theme history survives reload"), wait_for(sprintf(
      "document.getElementById('chat_%s')?.innerText.includes('Theme reply: %s theme question')", mode, mode
    )))
  }
  check("all scoped palettes survive reload", identical(palette(), initial))
  check("host colors remain unchanged after reload", host_colors_unchanged())
  scheme("dark")
  check("remounted auto theme keeps its live media listener", wait_for("document.getElementById('chat_auto').classList.contains('dark')"))
  check("zero console errors or runtime exceptions", length(errors) == 0L)
  check("zero network or HTTP errors", length(network_errors) == 0L)
  if (length(failures)) {
    stop("Theme verification failed: ", paste(failures, collapse = ", "), call. = FALSE)
  }
  cat("THEME_VERIFY_DONE checks=", checks, "\n", sep = "")
}

main()
