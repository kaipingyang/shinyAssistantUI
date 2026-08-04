# Plan 52.B verify: make_codeagent_remote_handler end-to-end in ONE process,
# with a NON-FAKEABLE assertion (a real filesystem side effect only possible if a
# gated tool is approved AND executed in the worker). MAIN loads shinyAssistantUI
# but NEVER ellmer/codeagent/curl.
#   Round A (approve): a gated tool must fire (req_approval) AND the file appears.
#   Round B (deny):    the gated tool fires but the file must NOT appear.
HOME_LIB <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
.libPaths(c(HOME_LIB, .Library))
suppressMessages({ library(shinyAssistantUI); library(promises); library(later) })
`%||%` <- function(x,y) if(is.null(x))y else x
NEWLIB <- "/usrfiles/shared-projects/users/kaiping_yang/Rlibs/codeagent/R-4.4"
PROJ   <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"

run_turn <- function(thread_id, approve, proof) {
  if (file.exists(proof)) file.remove(proof)
  dir.create(dirname(proof), showWarnings = FALSE, recursive = TRUE)
  h <- make_codeagent_remote_handler(
    config = list(cwd = dirname(proof)), libpath = NEWLIB,
    renviron = file.path(PROJ, ".Renviron"), permission_mode = "default")
  cap <- new.env(); cap$done <- FALSE; cap$req_approval <- FALSE; cap$asks <- 0L
  prompt <- sprintf("Use your tools to create a file at the absolute path '%s' whose exact contents are the text HELLO42. Do it now with a single tool call.", proof)
  h(message = prompt, thread_id = thread_id, attachments = list(),
    on_chunk = function(t) NULL, on_done = function(...) cap$done <- TRUE, on_error = function(m) cap$err <- m,
    on_tool_call = function(tool_call_id, tool_name, args, annotations) {
      if (isTRUE(annotations$requiresApproval)) cap$req_approval <- TRUE },
    on_tool_result = function(...) NULL, on_thinking = NULL,
    on_image = function(...) NULL, on_artifact = function(...) NULL,
    is_cancelled = function() FALSE,
    wait_for_approval = function(id) { cap$asks <- cap$asks + 1L; promises::promise_resolve(list(approved = approve)) },
    register_cancel = function(fn) NULL)
  for (i in 1:3000) { later::run_now(); if (isTRUE(cap$done)) break; Sys.sleep(0.05) }
  list(req_approval = cap$req_approval, asks = cap$asks, done = cap$done,
       file = file.exists(proof), err = cap$err)
}

proofA <- file.path(tempdir(), "ca_remoteA", "PROOF.txt")
proofB <- file.path(tempdir(), "ca_remoteB", "PROOF.txt")
A <- run_turn("tA", TRUE,  proofA)
B <- run_turn("tB", FALSE, proofB)

curl_main <- "curl" %in% loadedNamespaces(); ell_main <- "ellmer" %in% loadedNamespaces(); ca_main <- "codeagent" %in% loadedNamespaces()
cat(sprintf("A: req_approval=%s asks=%d done=%s file=%s | B: req_approval=%s file=%s\n",
    A$req_approval, A$asks, A$done, A$file, B$req_approval, B$file))
cat(sprintf("[%s] gated tool raised approval across process boundary (both rounds asked)\n", if(isTRUE(A$req_approval) && isTRUE(B$req_approval))"PASS" else "FAIL"))
cat(sprintf("[%s] APPROVE -> tool executed (file created)\n", if(isTRUE(A$file))"PASS" else "FAIL"))
cat(sprintf("[%s] DENY -> tool blocked (file NOT created)\n", if(!isTRUE(B$file))"PASS" else "FAIL"))
cat(sprintf("[%s] MAIN never loaded curl/ellmer/codeagent (ERP-safe isolation)\n", if(!curl_main && !ell_main && !ca_main)"PASS" else "FAIL"))
if(!is.null(A$err)) cat("  A err:", A$err, "\n"); if(!is.null(B$err)) cat("  B err:", B$err, "\n")
cat("REMOTE_VERIFY_DONE\n")
