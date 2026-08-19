# Out-of-process codeagent worker transport (Plan 52.A).
#
# Runs a codeagent turn in a separate R process pinned to a lib with a new curl
# (for example Rlibs/codeagent/R-4.4), so the MAIN Shiny/ERP process never loads
# codeagent/ellmer/curl. Streaming deltas, tool events, and interactive
# permission approval are marshaled over a socket as newline-delimited JSON.
#
# IMPORTANT: nothing in this file may library()/requireNamespace("codeagent")
# in the MAIN process. codeagent/ellmer/curl load only inside the worker process.
# Availability is checked with find.package(lib.loc=) without loading it.

# codeagent availability WITHOUT loading it into MAIN (must NOT requireNamespace).
.ca_worker_available <- function(libpath = NULL) {
  isTRUE(tryCatch(
    nzchar(find.package("codeagent", lib.loc = libpath, quiet = TRUE)[1]),
    error = function(e) FALSE
  ))
}

# ── worker body (runs in the r_bg process; must be self-contained) ───────────
# Builds ONE codeagent client (from `config`), installs the permission gate with
# an ask_fn that marshals asks to MAIN, then loops handling run/approve/cancel/
# stop commands. The client persists across runs -> multi-turn memory.
# NOTE: this function runs in a FRESH R process (callr) that has NOT loaded the
# shinyAssistantUI package — it must reference only base + libs loaded inside.
.ca_worker_body <- function(libpath, renviron, config, port) {
  .libPaths(c(libpath, .Library))
  if (nzchar(renviron) && file.exists(renviron)) readRenviron(renviron)
  worker_packages <- c("ellmer", "codeagent", "promises", "later", "jsonlite")
  invisible(lapply(worker_packages, loadNamespace))
  `%||%` <- function(x, y) if (is.null(x)) y else x
  con <- socketConnection(host = "127.0.0.1", port = port, server = TRUE,
                          blocking = FALSE, open = "r+b")
  on.exit(try(close(con), silent = TRUE), add = TRUE)
  send <- function(obj) {
    tryCatch({
      writeLines(as.character(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null")), con); flush(con)
    }, error = function(e) {
      # never let a serialization failure break the stream; drop to a plain note
      tryCatch({ writeLines(as.character(jsonlite::toJSON(
        list(ev = obj$ev %||% "note", note = "unserializable payload dropped"),
        auto_unbox = TRUE, null = "null")), con); flush(con) }, error = function(e2) NULL)
    })
  }
  # codeagent's display$toolcard may hold htmltools shiny.tag objects (not JSON-
  # serializable). Extract only the JSON-safe fields .codeagent_display_to_ui reads.
  safe_display <- function(d) {
    tc <- tryCatch(d$toolcard, error = function(e) NULL)
    if (is.null(tc)) return(NULL)
    p <- tryCatch(tc$payload, error = function(e) NULL) %||% list()
    imgs <- lapply(p$images %||% list(), function(im)
      list(mime = im$mime %||% im$type %||% "image/png", b64 = im$b64 %||% NULL, src = im$src %||% NULL))
    list(
      toolcard = list(
        kind    = tryCatch(as.character(tc$kind %||% "text"), error = function(e) "text"),
        title   = tryCatch(as.character(tc$title %||% ""), error = function(e) ""),
        payload = list(text = tryCatch(as.character(p$text %||% ""), error = function(e) ""),
                       lang = tryCatch(as.character(p$lang %||% ""), error = function(e) ""),
                       images = imgs)),
      markdown = tryCatch(as.character(d$markdown %||% ""), error = function(e) "")
    )
  }

  chat <- ellmer::chat_openai_compatible(
    base_url    = config$base_url %||% Sys.getenv("OPENAI_BASE_URL"),
    model       = config$model    %||% Sys.getenv("OPENAI_MODEL"),
    credentials = function() config$api_key %||% Sys.getenv("OPENAI_API_KEY")
  )
  cl <- codeagent::codeagent_client(chat = chat, register_tools = TRUE,
                                    permission_mode = config$permission_mode %||% "default",
                                    cwd = config$cwd %||% getwd())

  pend <- new.env(parent = emptyenv())        # ask id -> resolve fn
  ask_fn <- function(name, input, id = NULL) {
    tuid <- id %||% paste0("ask", as.integer(stats::runif(1, 1, 1e9)))
    send(list(ev = "ask", id = tuid, name = name, args = input))
    promises::promise(function(resolve, reject) assign(tuid, resolve, envir = pend))
  }
  tryCatch(codeagent::install_permission_gate(
    cl$chat, permission_mode = config$permission_mode %||% "default",
    ask_fn = ask_fn, rules = config$rules %||% list()), error = function(e) NULL)

  ctrl <- ellmer::stream_controller()
  running <- FALSE; stop_now <- FALSE

  start_run <- function(prompt) {
    running <<- TRUE
    tryCatch(ctrl$reset(), error = function(e) NULL)
    codeagent::codeagent_stream_async(
      cl, prompt, controller = ctrl,
      on_delta        = function(t) send(list(ev = "delta", t = t)),
      on_thinking     = function(t) send(list(ev = "thinking", t = t)),
      on_tool_request = function(req) send(list(ev = "tool_req", id = req$id %||% "",
                            name = req$name %||% "", args = req$arguments %||% list(),
                            intent = req$intent %||% "")),
      on_tool_result  = function(rr) send(list(ev = "tool_res", id = rr$id %||% "",
                            name = rr$name %||% "", value = as.character(rr$value %||% ""),
                            is_error = isTRUE(rr$is_error),
                            display = safe_display(tryCatch(rr$display, error = function(e) NULL)))),
      on_error        = function(m, recovered = FALSE) send(list(ev = "error", m = m))
    )$then(function(x) { send(list(ev = "done", text = x$text %||% "",
                                   stop_reason = x$stop_reason %||% "")); running <<- FALSE
      })$catch(function(e) { send(list(ev = "error", m = conditionMessage(e)));
                             send(list(ev = "done", text = "")); running <<- FALSE })
  }

  send(list(ev = "ready"))
  repeat {
    later::run_now(timeout = 0.02)
    ins <- tryCatch(readLines(con, warn = FALSE), error = function(e) character(0))  # complete lines
    for (l in ins) {
      if (!nzchar(l)) next
      cmd <- tryCatch(jsonlite::fromJSON(l), error = function(e) NULL)
      if (is.null(cmd$cmd)) next
      if (identical(cmd$cmd, "run") && !running) start_run(cmd$prompt %||% "")
      else if (identical(cmd$cmd, "approve")) {
        r <- get0(cmd$id %||% "", envir = pend, ifnotfound = NULL)
        if (is.function(r)) { r(isTRUE(cmd$ok)); rm(list = cmd$id, envir = pend) }
      } else if (identical(cmd$cmd, "cancel")) tryCatch(ctrl$cancel("User interrupted"), error = function(e) NULL)
      else if (identical(cmd$cmd, "stop")) stop_now <- TRUE
    }
    if (stop_now && !running) break
    Sys.sleep(0.01)
  }
  send(list(ev = "closed")); Sys.sleep(0.2)
}

# ── MAIN-side handle + transport (loads only callr/jsonlite/later/promises) ───
.ca_worker_start <- function(libpath, renviron = NULL, config = list(),
                             port = NULL, connect_timeout = 25) {
  if (!requireNamespace("callr", quietly = TRUE))
    stop("out-of-process codeagent requires the 'callr' package.", call. = FALSE)
  port <- port %||% as.integer(sample(20000:60000, 1))
  proc <- callr::r_bg(func = .ca_worker_body,
                      args = list(libpath = libpath, renviron = renviron %||% "",
                                  config = config, port = port),
                      supervise = TRUE)
  con <- NULL; deadline <- Sys.time() + connect_timeout
  while (is.null(con) && Sys.time() < deadline && proc$is_alive()) {
    Sys.sleep(0.3)
    con <- tryCatch(socketConnection(host = "127.0.0.1", port = port, server = FALSE,
                                     blocking = FALSE, open = "r+b"), error = function(e) NULL)
  }
  if (is.null(con)) { try(proc$kill(), silent = TRUE); stop("codeagent worker did not accept a connection.", call. = FALSE) }
  h <- new.env(parent = emptyenv()); h$proc <- proc; h$con <- con; h$port <- port; h
}

.ca_worker_send <- function(h, obj) {
  tryCatch({ writeLines(as.character(jsonlite::toJSON(obj, auto_unbox = TRUE, null = "null")), h$con); flush(h$con) },
           error = function(e) NULL)
}

# Drive one turn: send `run`, then later-poll the socket, calling on_event(ev)
# for each decoded event. Returns a promise resolving on the `done` event (or
# rejecting if the worker dies). Approval is handled by the caller inside on_event.
.ca_worker_run <- function(h, prompt, on_event) {
  promises::promise(function(resolve, reject) {
    .ca_worker_send(h, list(cmd = "run", prompt = prompt))
    settled <- FALSE
    poll <- function() {
      if (settled) return(invisible())
      if (!h$proc$is_alive()) { settled <<- TRUE; reject(simpleError("codeagent worker process died")); return(invisible()) }
      lines <- tryCatch(readLines(h$con, warn = FALSE), error = function(e) character(0))  # complete frames
      for (l in lines) {
        if (!nzchar(l)) next
        ev <- tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE), error = function(e) NULL)
        if (is.null(ev$ev)) next
        tryCatch(on_event(ev), error = function(e) NULL)
        if (identical(ev$ev, "done")) { settled <<- TRUE; resolve(ev); return(invisible()) }
      }
      later::later(poll, 0.04)
    }
    poll()
  })
}

.ca_worker_cancel <- function(h) .ca_worker_send(h, list(cmd = "cancel"))
.ca_worker_stop   <- function(h) {
  .ca_worker_send(h, list(cmd = "stop"))
  later::later(function() { try(close(h$con), silent = TRUE); try(h$proc$kill(), silent = TRUE) }, 0.5)
}
