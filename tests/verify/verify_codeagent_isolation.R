# Plan 52 make-or-break spike: out-of-process codeagent worker.
# MAIN process (models ERP old-curl session) NEVER loads ellmer/curl. It spawns a
# WORKER R process pinned to the codeagent lib (new curl), which runs a real
# codeagent turn and marshals streaming deltas + a permission-approval round-trip
# back over a socket. Proves process isolation is feasible for the ERP addin.
#
# PASS = MAIN loadedNamespaces() has NO curl/ellmer, worker streamed, an ask was
#        marshaled to MAIN + approved, and the tool executed (42 seen).
suppressMessages({library(callr); library(jsonlite)})   # MAIN: no ellmer/codeagent/curl
`%||%` <- function(x,y) if(is.null(x))y else x
NEWLIB <- "/usrfiles/shared-projects/users/kaiping_yang/Rlibs/codeagent/R-4.4"
PROJ   <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
PORT   <- 8799L

worker <- function(lib, port, renviron) {
  .libPaths(c(lib, .Library))                 # WORKER: only codeagent lib + base -> NEW curl
  readRenviron(renviron)
  suppressMessages({library(ellmer); library(codeagent); library(promises); library(later); library(jsonlite)})
  `%||%` <- function(x,y) if(is.null(x))y else x
  con <- socketConnection(host="127.0.0.1", port=port, server=TRUE, blocking=FALSE, open="r+b")
  send <- function(obj) { writeLines(jsonlite::toJSON(obj, auto_unbox=TRUE), con); flush(con) }
  # await the run command
  prompt <- NULL
  for(i in 1:400){ ls<-readLines(con,warn=FALSE); if(length(ls)){ m<-tryCatch(jsonlite::fromJSON(ls[[1]]),error=function(e)NULL); if(!is.null(m$prompt)){prompt<-m$prompt;break} }; Sys.sleep(0.05) }
  if(is.null(prompt)){ send(list(ev="done",text="NO PROMPT")); close(con); return(invisible()) }

  pend <- new.env()
  chat <- chat_openai_compatible(base_url=Sys.getenv("OPENAI_BASE_URL"),
            model=Sys.getenv("OPENAI_MODEL"), credentials=function() Sys.getenv("OPENAI_API_KEY"))
  scratch <- file.path(tempdir(),"iso"); dir.create(scratch,showWarnings=FALSE)
  cl <- codeagent::codeagent_client(chat=chat, register_tools=TRUE, permission_mode="default", cwd=scratch)
  ask_fn <- function(name, input, id=NULL){
    tuid <- id %||% paste0("t", as.integer(stats::runif(1,1,1e6)))
    send(list(ev="ask", id=tuid, name=name))                       # marshal ASK to MAIN
    promises::promise(function(resolve, reject) assign(tuid, resolve, envir=pend))
  }
  codeagent::install_permission_gate(cl$chat, permission_mode="default", ask_fn=ask_fn)

  done <- FALSE
  codeagent::codeagent_stream_async(cl, prompt,
    on_delta       = function(t) send(list(ev="delta", t=t)),
    on_tool_request= function(req) send(list(ev="tool_req", name=req$name %||% "?")),
    on_tool_result = function(rr) send(list(ev="tool_res", v=substr(as.character(rr$value %||% ""),1,80))),
    on_error       = function(m,...) send(list(ev="error", m=m))
  )$then(function(x){ send(list(ev="done", text=substr(x$text %||% "",1,120))); done<<-TRUE
    })$catch(function(e){ send(list(ev="done", text=paste("CATCH",conditionMessage(e)))); done<<-TRUE })

  for(i in 1:6000){                                                # pump async + poll approvals
    later::run_now(timeout=0.02)
    ls <- readLines(con, warn=FALSE)
    for(l in ls){ if(nzchar(l)){ c2<-tryCatch(jsonlite::fromJSON(l),error=function(e)NULL)
      if(!is.null(c2) && identical(c2$cmd,"approve")){ r<-get0(c2$id, envir=pend, ifnotfound=NULL); if(is.function(r)) r(isTRUE(c2$ok)) } } }
    if(done) break; Sys.sleep(0.01)
  }
  send(list(ev="closed")); Sys.sleep(0.3); close(con)
}

p <- callr::r_bg(worker, args=list(lib=NEWLIB, port=PORT, renviron=file.path(PROJ,".Renviron")),
                 stdout="/tmp/isw.o", stderr="/tmp/isw.e")
on.exit({try(p$kill(),silent=TRUE); system("rm -f /tmp/isw.*")}, add=TRUE)
Sys.sleep(4)                                                       # let worker bind server socket
con <- tryCatch(socketConnection(host="127.0.0.1", port=PORT, server=FALSE, blocking=FALSE, open="r+b"),
                error=function(e){cat("MAIN connect fail:",conditionMessage(e),"\n"); NULL})
if(is.null(con)){ cat(tail(readLines("/tmp/isw.e"),15),sep="\n"); quit(status=1) }
writeLines(jsonlite::toJSON(list(prompt="Use run_r to compute 6*7 and print only the number. One tool call."), auto_unbox=TRUE), con); flush(con)

events<-c(); asked<-FALSE; done<-FALSE; final<-""
for(i in 1:1500){
  ls <- readLines(con, warn=FALSE)
  for(l in ls){ if(nzchar(l)){ ev<-tryCatch(jsonlite::fromJSON(l),error=function(e)NULL); if(is.null(ev$ev)) next
    events<-c(events, ev$ev)
    if(identical(ev$ev,"delta")) cat(ev$t)
    if(identical(ev$ev,"tool_res")) cat("\n[MAIN tool_res]", ev$v, "\n")
    if(identical(ev$ev,"ask")){ asked<-TRUE; cat("\n[MAIN got ASK ->approve]", ev$name, "\n")
      writeLines(jsonlite::toJSON(list(cmd="approve", id=ev$id, ok=TRUE), auto_unbox=TRUE), con); flush(con) }
    if(identical(ev$ev,"done")){ final<-ev$text %||% ""; cat("\n[DONE]", final, "\n"); done<-TRUE }
  }}
  if(done) break
  if(!p$is_alive()){ cat("\nWORKER DIED\n"); cat(tail(readLines("/tmp/isw.e"),15),sep="\n"); break }
  Sys.sleep(0.1)
}
close(con)
curl_in_main <- "curl" %in% loadedNamespaces(); ell_in_main <- "ellmer" %in% loadedNamespaces()
got42 <- grepl("42", paste(c(final, events), collapse=" ")) || any(grepl("42", events))
cat("\n\n=== events:", paste(unique(events),collapse=","), "===\n")
cat("=== MAIN loaded curl:", curl_in_main, " ellmer:", ell_in_main, "===\n")
cat(sprintf("[%s] worker streamed a real codeagent turn (delta/tool events)\n", if("delta" %in% events || "tool_req" %in% events)"PASS" else "FAIL"))
cat(sprintf("[%s] approval round-trip marshaled to MAIN and back\n", if(asked)"PASS" else "FAIL"))
cat(sprintf("[%s] tool executed after approval (42)\n", if(got42)"PASS" else "FAIL"))
cat(sprintf("[%s] MAIN process never loaded curl/ellmer (ERP-safe isolation)\n", if(!curl_in_main && !ell_in_main)"PASS" else "FAIL"))
cat("ISOLATION_SPIKE_DONE\n")
