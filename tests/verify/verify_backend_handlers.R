# AUI_BACKEND=ellmer|codeagent|remote|shield; bounded browser runner, --timeout 180.
# AUI_BACKEND_MODE=performance checks 200-fragment fast/slow streams and remote idle CPU.
# ellmer-direct is a performance-only public-API baseline, not a handler acceptance.
local({
  backend <- Sys.getenv("AUI_BACKEND", "codeagent")
  stopifnot(backend %in% c("ellmer", "ellmer-direct", "codeagent", "remote", "shield"))
  mode <- Sys.getenv("AUI_BACKEND_MODE", "protocol")
  stopifnot(mode %in% c("protocol", "performance", "profile"),
            mode == "protocol" || backend != "shield",
            backend != "ellmer-direct" || mode == "performance")
  project <- normalizePath(".")
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(identical(
    normalizePath(find.package("shinyAssistantUI")),
    file.path(home, "shinyAssistantUI")
  ))
  output <- Sys.getenv("AUI_BACKEND_OUT", tempfile(paste0("backend-", backend, "-")))
  root <- tempfile(paste0("backend-protocol-", backend, "-"))
  dir.create(root, mode = "0700")
  browser <- app <- model <- NULL
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit(
    {
      if (!is.null(model) && model$is_alive()) model$kill_tree()
      cleanup()
      unlink(root, recursive = TRUE)
    },
    add = TRUE
  )
  model_port <- httpuv::randomPort()
  app_port <- httpuv::randomPort()
  while (app_port == model_port) app_port <- httpuv::randomPort()
  model <- processx::process$new(
    "python3", c(
      file.path(project, "tests/verify/fixtures/openai_backend_stream.py"),
      "--port", model_port, "--root", root
    ),
    stdout = file.path(root, "model.out"), stderr = file.path(root, "model.err"),
    supervise = TRUE, cleanup_tree = TRUE
  )
  model_url <- paste0("http://127.0.0.1:", model_port)
  deadline <- Sys.time() + 10
  ready <- FALSE
  while (!ready && Sys.time() < deadline) {
    stopifnot(model$is_alive())
    ready <- tryCatch(curl::curl_fetch_memory(model_url)$status_code == 200L,
      error = function(error) FALSE
    )
    if (!ready) Sys.sleep(0.05)
  }
  stopifnot(ready)
  app <- callr::r_bg(
    function(root, backend, home, app_port, model_url, profile) {
      .libPaths(c(home, .libPaths()))
      setwd(root)
      dir.create(file.path(root, "home"))
      Sys.setenv(
        HOME = file.path(root, "home"), CODEAGENT_HOME = file.path(root, "settings"),
        CODEAGENT_API_KEY = "local-fixture", CODEAGENT_MODEL = "gpt-4.1",
        CODEAGENT_BASE_URL = paste0(model_url, "/v1/")
      )
      options(shiny.deepstacktrace = TRUE)
      suppressPackageStartupMessages({
        library(shiny)
        library(shinyAssistantUI, lib.loc = home)
      })
      stopifnot(identical(
        normalizePath(find.package("shinyAssistantUI")),
        file.path(home, "shinyAssistantUI")
      ))
      metrics <- list(runs = list(), tools = 0L, errors = character(), closed = 0L)
      publish <- function() {
        path <- file.path(root, "metrics.rds")
        saveRDS(metrics, paste0(path, ".tmp"))
        stopifnot(file.rename(paste0(path, ".tmp"), path))
      }
      new_chat <- function() {
        ellmer::chat_openai_compatible(
          base_url = paste0(model_url, "/v1/"), model = "gpt-4.1",
          credentials = function() "local-fixture", echo = "none"
        )
      }
      ui <- bslib::page_fluid(
        tags$head(tags$link(rel = "icon", href = "data:,")),
        assistantUIOutput("chat", height = "90vh")
      )
      server <- function(input, output, session) {
        echo <- NULL
        if (backend != "remote") {
          echo <- ellmer::tool(
            function(value) {
              metrics$tools <<- metrics$tools + 1L
              publish()
              paste0("ECHO_", value)
            },
            name = "Echo", description = "Return a synthetic verification value.",
            arguments = list(value = ellmer::type_string("Synthetic value."))
          )
        }
        handler <- if (backend == "ellmer-direct") {
          direct_chat <- new_chat()
          coro::async(function(message, on_chunk, on_done) {
            for (chunk in coro::await_each(direct_chat$stream_async(message))) on_chunk(chunk)
            on_done()
          })
        } else if (backend == "ellmer") {
          make_ellmer_handler(new_chat, tools = list(echo), approval_tools = "Echo")
        } else if (backend == "remote") {
          make_codeagent_remote_handler(
            config = list(
              cwd = root, base_url = paste0(model_url, "/v1/"),
              model = "gpt-4.1", api_key = "local-fixture"
            ),
            libpath = home, permission_mode = "default"
          )
        } else {
          make_codeagent_handler(
            client_factory = function() {
              chat <- new_chat()
              chat$register_tool(echo)
              shield <- NULL
              if (backend == "shield") {
                shield <- codeagent::DataShield$new(strategies = list(
                  codeagent::shield_egress(max_rows = 0L)
                ))
                shield$register_data(data.frame(
                  id = sprintf("FAKEID%03d", seq_len(20L))
                ), "protected_demo", cols = "id")
              }
              codeagent::codeagent_client(
                chat = chat, register_tools = FALSE, cwd = root, data_shield = shield
              )
            },
            permission_mode = "default", approval_tools = "Echo",
            gate_fn = function(chat, permission_mode, ask_fn, rules) {
              codeagent::install_permission_gate(
                chat, permission_mode = permission_mode, ask_fn = ask_fn,
                rules = rules, tool_meta = list(Echo = "read")
              )
            }
          )
        }
        wrapped <- function(...) {
          args <- list(...)
          index <- length(metrics$runs) + 1L
          marker <- regmatches(args$message, regexpr("AUI_[A-Z_]+", args$message))
          metrics$runs[[index]] <<- list(
            marker = marker, started = as.numeric(Sys.time()), chunks = 0L,
            done = 0L, cancelled = 0L, settled = FALSE
          )
          original_chunk <- args$on_chunk
          original_done <- args$on_done
          original_error <- args$on_error
          original_cancel <- args$register_cancel
          args$on_chunk <- function(text) {
            metrics$runs[[index]]$chunks <<- metrics$runs[[index]]$chunks + 1L
            if (metrics$runs[[index]]$chunks == 1L) {
              metrics$runs[[index]]$first <<- as.numeric(Sys.time())
              publish()
            }
            original_chunk(text)
          }
          args$on_done <- function(...) {
            metrics$runs[[index]]$done <<- metrics$runs[[index]]$done + 1L
            publish()
            original_done(...)
          }
          args$on_error <- function(message) {
            metrics$errors <<- c(metrics$errors, message)
            publish()
            original_error(message)
          }
          args$register_cancel <- function(fn) {
            original_cancel(function() {
              metrics$runs[[index]]$cancelled <<- metrics$runs[[index]]$cancelled + 1L
              publish()
              fn()
            })
          }
          publish()
          profiling <- profile && identical(marker, "AUI_FAST_WARM")
          if (profiling) utils::Rprof(file.path(root, "warm-stream-cpu.out"), interval = 0.01)
          value <- do.call(handler, args[names(args) %in% names(formals(handler))])
          promises::then(value, function(result) {
            if (profiling) utils::Rprof(NULL)
            metrics$runs[[index]]$settled <<- TRUE
            metrics$runs[[index]]$finished <<- as.numeric(Sys.time())
            publish()
            result
          }, function(error) {
            if (profiling) utils::Rprof(NULL)
            metrics$errors <<- c(metrics$errors, conditionMessage(error))
            publish()
            stop(error)
          })
        }
        attributes(wrapped) <- attributes(handler)
        api <- assistantUIServer(
          "chat", wrapped,
          persistence = "server", show_thread_list = TRUE,
          on_session_load = function(session_id, thread_id, send_thread, ...) {
            send_thread(list(
              list(id = "history-tool", role = "assistant", content = list(list(
                type = "tool-call", toolCallId = "history-tool", toolName = "Echo",
                args = list(value = "stored"),
                argsText = as.character(jsonlite::toJSON(list(value = "stored"), auto_unbox = TRUE)),
                result = "HISTORY_BACKEND_TOOL"
              ))),
              list(
                id = "history-text", role = "assistant",
                content = list(list(type = "text", text = "HISTORY_BACKEND_READY"))
              )
            ))
          }
        )
        session$onFlushed(function() {
          api$send_sessions(list(sessions = list(list(
            id = "backend-history", title = "Backend history"
          ))))
        }, once = TRUE)
        session$onSessionEnded(function() {
          metrics$closed <<- metrics$closed + 1L
          publish()
        })
        publish()
      }
      check_stop <- function() {
        if (file.exists(file.path(root, "stop"))) {
          stopApp()
        } else {
          later::later(check_stop, 0.1)
        }
      }
      later::later(check_stop, 0.1)
      runApp(shinyApp(ui, server), host = "127.0.0.1", port = app_port, launch.browser = FALSE)
    },
    args = list(
      root = root, backend = backend, home = home,
      app_port = app_port, model_url = model_url, profile = identical(mode, "profile")
    ),
    stdout = file.path(root, "app.out"), stderr = file.path(root, "app.err"),
    supervise = TRUE, user_profile = FALSE, system_profile = FALSE
  )
  wait <- function(predicate, timeout = 25, label = "condition") {
    deadline <- Sys.time() + timeout
    repeat {
      if (!app$is_alive() || !model$is_alive() || Sys.time() > deadline) {
        cat(tail(readLines(file.path(root, "app.err"), warn = FALSE), 25L), sep = "\n")
        cat(tail(readLines(file.path(root, "model.err"), warn = FALSE), 15L), sep = "\n")
        stop("Backend verification stopped: ", backend, " / ", label)
      }
      if (isTRUE(predicate())) {
        return(invisible(TRUE))
      }
      Sys.sleep(0.05)
    }
  }
  wait(function() {
    any(grepl(
      "Listening on", readLines(file.path(root, "app.err"), warn = FALSE),
      fixed = TRUE
    ))
  })
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- chromote::ChromoteSession$new(width = 1100, height = 800)
  errors <- network_errors <- 0L
  websocket_frames <- character()
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- errors + 1L
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) errors <<- errors + 1L)
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors <<- network_errors + 1L
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- network_errors + 1L
  })
  browser$Network$webSocketFrameReceived(callback_ = function(event) {
    if (backend == "shield") websocket_frames <<- c(websocket_frames, event$response$payloadData)
  })
  js <- function(code) {
    value <- browser$Runtime$evaluate(code, returnByValue = TRUE)
    if (!is.null(value$exceptionDetails)) stop("Backend browser evaluation failed")
    value$result$value
  }
  has <- function(text) {
    sprintf(
      "document.body.innerText.includes(%s)", jsonlite::toJSON(text, auto_unbox = TRUE)
    )
  }
  check <- function(label, code) {
    wait(function() isTRUE(js(code)), label = label)
    cat("[PASS] ", backend, ": ", label, "\n", sep = "")
  }
  metrics <- function() readRDS(file.path(root, "metrics.rds"))
  send <- function(text) {
    check("composer ready", "!!document.querySelector('[contenteditable=true]')&&!!document.querySelector('.aui-composer-send')")
    js("document.querySelector('[contenteditable=true]').focus(); true")
    browser$Input$insertText(text)
    check("send enabled", "!!document.querySelector('.aui-composer-send:not([disabled])')")
    browser$Input$dispatchKeyEvent(
      type = "keyDown", key = "Enter", code = "Enter",
      windowsVirtualKeyCode = 13L
    )
    browser$Input$dispatchKeyEvent(
      type = "keyUp", key = "Enter", code = "Enter",
      windowsVirtualKeyCode = 13L
    )
  }
  settled <- function(count) {
    wait(function() {
      value <- metrics()
      length(value$runs) >= count && isTRUE(value$runs[[count]]$settled)
    }, label = paste("turn", count, "settled"))
  }
  history <- function() {
    check("history available", "[...document.querySelectorAll('button')].some(b=>b.innerText.includes('Backend history'))")
    js("[...document.querySelectorAll('button')].find(b=>b.innerText.includes('Backend history')).click(); true")
    check("history restored", has("HISTORY_BACKEND_READY"))
    js("document.querySelector('[data-slot=tool-fallback-trigger]').click(); true")
    check("history tool restored", has("HISTORY_BACKEND_TOOL"))
  }
  browser$Page$navigate(paste0("http://127.0.0.1:", app_port))
  check("installed widget mounted", "!!document.querySelector('.aui-root')")
  history()
  performance_ok <- TRUE
  idle_worker_cpu <- NULL
  if (mode %in% c("performance", "profile")) {
    markers <- c("AUI_FAST_COLD", "AUI_FAST_WARM")
    if (mode == "performance") markers <- c(markers, "AUI_SLOW")
    for (index in seq_along(markers)) {
      marker <- markers[[index]]
      send(marker)
      check("performance stream starts", has(paste0(marker, "_00")))
      settled(index)
      expected <- paste(sprintf("%s_%02d", marker, 0:199), collapse = " ")
      check("all 200 fragments reach the DOM in order", sprintf(
        "document.body.innerText.replace(/\\s+/g,' ').includes(%s)",
        jsonlite::toJSON(expected, auto_unbox = TRUE)
      ))
    }
    rows <- lapply(metrics()$runs, function(run) data.frame(
      marker = run$marker, first_seconds = run$first - run$started,
      complete_seconds = run$finished - run$started,
      chunks = run$chunks, done = run$done
    ))
    timings <- do.call(rbind, rows)
    print(timings, row.names = FALSE)
    performance_ok <- mode == "profile" || (all(timings$chunks >= 200L) &&
      all(timings$done == 1L) &&
      timings$complete_seconds[[1L]] < 15 &&
      timings$complete_seconds[[2L]] < 4 &&
      timings$complete_seconds[[3L]] >= 19.9 &&
      timings$complete_seconds[[3L]] < 30)
    if (backend == "remote" && mode == "performance") {
      workers <- ps::ps_children(ps::ps_handle(app$get_pid()), recursive = TRUE)
      stopifnot(length(workers) > 0L)
      cpu <- function() sum(vapply(workers, function(handle) {
        sum(unlist(ps::ps_cpu_times(handle)[c("user", "system")]))
      }, numeric(1)))
      before <- cpu()
      Sys.sleep(1)
      idle_worker_cpu <- cpu() - before
      cat("IDLE_WORKER_CPU_SECONDS ", idle_worker_cpu, "\n", sep = "")
      performance_ok <- performance_ok && idle_worker_cpu < 0.4
    }
  } else if (backend == "shield") {
    send("AUI_SHIELD")
    settled(1L)
    check("scanned response is actually rendered", has("[REDACTED]"))
    stopifnot(
      metrics()$runs[[1L]]$chunks == 1L,
      !isTRUE(js(has("FAKEID001"))),
      !grepl("FAKEID001", paste(websocket_frames, collapse = "\n"), fixed = TRUE)
    )
    cat("[PASS] shield: final scan precedes the only text release; no raw WebSocket value\n")
  } else {
    send("AUI_NORMAL_COLD")
    check("live text arrives", has("AUI_NORMAL_COLD_00"))
    settled(1L)
    check("complete stream", has("AUI_NORMAL_COLD_19"))
    stopifnot(metrics()$runs[[1L]]$chunks >= 2L)
    for (action in c("APPROVE", "DENY")) {
      send(paste0("AUI_", action))
      check("real approval card", "!!document.querySelector('.aui-shiny-approval')")
      check("approval button visible", paste0(
        "[...document.querySelectorAll('.aui-shiny-approval button')].some(b=>",
        "b.innerText.trim()==='Approve'&&!b.disabled)"
      ))
      check("approval card is in the viewport", paste0(
        "(()=>{const b=[...document.querySelectorAll('.aui-shiny-approval button')]",
        ".filter(b=>b.innerText.trim()==='Approve'&&!b.disabled).at(-1);",
        "const r=b?.closest('.aui-shiny-approval')?.getBoundingClientRect();",
        "return !!r&&r.height>0&&r.top>=0&&r.bottom<=innerHeight})()"
      ))
      stopifnot(!file.exists(file.path(root, paste0("proof-", tolower(action), ".txt"))))
      label <- if (action == "APPROVE") "Approve" else "Deny"
      js(sprintf(
        "[...document.querySelectorAll('.aui-shiny-approval button')].filter(b=>b.innerText.trim()==='%s'&&!b.disabled).at(-1).click(); true",
        label
      ))
      check(paste(action, "continues"), has(paste0("AUI_", action, "_DONE")))
      settled(if (action == "APPROVE") 2L else 3L)
    }
    if (backend == "remote") {
      stopifnot(
        identical(readLines(file.path(root, "proof-approve.txt")), "APPROVED_PROOF"),
        !file.exists(file.path(root, "proof-deny.txt"))
      )
    } else {
      stopifnot(metrics()$tools == 1L)
    }
    send("AUI_CANCEL")
    check("real stream is cancellable", paste0(has("AUI_RUNNING_0000"), "&&!!document.querySelector('.aui-composer-cancel')"))
    js("document.querySelector('.aui-composer-cancel').click(); true")
    settled(4L)
    stopifnot(metrics()$runs[[4L]]$cancelled == 1L)
    send("AUI_NORMAL_RECOVER")
    check("same thread recovers after Stop", has("AUI_NORMAL_RECOVER_19"))
    settled(5L)
    send("AUI_QUIET")
    check("quiet backend resumes", has("AUI_QUIET_19"))
    settled(6L)
    if (backend == "remote") {
      send(paste0("AUI_LONG ", strrep("synthetic ", 9000L), " LONG_INPUT_SENTINEL"))
      check("large fragmented command survives", has("AUI_LONG_19"))
      settled(7L)
    }
  }
  snapshot <- metrics()
  stopifnot(length(snapshot$errors) == 0L, errors == 0L, network_errors == 0L)
  reload_origin <- js("String(performance.timeOrigin)")
  browser$Page$reload()
  check("reload remounts widget in a new document", sprintf(
    "String(performance.timeOrigin)!==%s&&document.readyState==='complete'&&!!document.querySelector('.aui-root')",
    jsonlite::toJSON(reload_origin, auto_unbox = TRUE)
  ))
  history()
  stopifnot(errors == 0L, network_errors == 0L)
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  saveRDS(list(
    backend = backend, mode = mode, metrics = snapshot, console_errors = errors,
    idle_worker_cpu_seconds = idle_worker_cpu,
    network_errors = network_errors, package_path = file.path(home, "shinyAssistantUI")
  ), file.path(output, "browser-results.rds"))
  stopifnot(file.copy(file.path(root, "model-events.jsonl"), file.path(output, "model-events.jsonl")))
  if (mode == "profile") {
    stopifnot(file.copy(file.path(root, "warm-stream-cpu.out"),
                       file.path(output, "warm-stream-cpu.out")))
  }
  file.create(file.path(root, "stop"))
  app$wait(5000)
  stopifnot(!app$is_alive(), app$get_exit_status() == 0L)
  model$kill_tree()
  model$wait(5000)
  stopifnot(!model$is_alive())
  cleanup()
  stopifnot(performance_ok)
  cat(if (mode == "profile") "BACKEND_PROFILE_RECORDED backend=" else "BACKEND_HANDLER_VERIFIED backend=", backend,
    " console=0 runtime=0 network=0 cleanup=true\n",
    sep = ""
  )
})
