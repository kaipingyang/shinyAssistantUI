# examples/27_codeagent_backend.R
# ─────────────────────────────────────────────────────────────────────────────
# codeagent as the backend engine (Plan 51, Phase A) — FULL built-in tools.
#
# make_codeagent_handler() drives a full `codeagent` agent. With
# `register_tools = TRUE` (default) codeagent brings its whole toolset:
# run_r (executes R — plots stream back INLINE as images), Read/Glob/Grep/LS,
# WebFetch/WebSearch, Write/Edit/Bash, etc. Ask it to "plot mtcars hp vs mpg and
# run it" and the chart appears in the conversation.
#
# ⚠️ PERMISSIONS (Phase A has no approval bridge yet — that's Phase B):
#   * permission_mode = "default": reads + WebFetch/WebSearch auto-allow, but
#     run_r / Write / Bash need confirmation → with no approval bridge they are
#     DENIED (so "execute this" won't run). Good for read-only Q&A.
#   * permission_mode = "bypass": almost everything auto-runs UNSUPERVISED
#     (run_r, Bash, Write...). Powerful for a demo, but the agent can execute
#     code and touch files without asking. Only use in a trusted, throwaway dir.
#   This example uses "bypass" + a scratch cwd so run_r/plots work out of the
#   box. Phase B will add the in-app approval card so you can use "default".
#
# For the *embed-your-own-domain-tools* pattern (no coding tools), instead use
# codeagent_client(register_tools = FALSE) and register your tools on the chat
# (see the spike examples/codeagent-backend-spike.R).
#
# PREREQUISITES: `codeagent` installed; repo-root .Renviron with
#   OPENAI_BASE_URL / OPENAI_MODEL / OPENAI_API_KEY (as in examples/09,10).
#
# RUN:  shiny::runApp("examples/27_codeagent_backend.R")
#   try: "Plot mtcars hp vs mpg with ggplot2 and run it"   → inline chart
#        "What is 12 * 13?"                                 → run_r computes it
# ─────────────────────────────────────────────────────────────────────────────
library(shiny)
library(ellmer)
library(codeagent)
devtools::load_all(here::here())

readRenviron(here::here(".Renviron"))

# Scratch working dir so the agent's file operations stay contained.
scratch <- file.path(tempdir(), "codeagent-demo")
dir.create(scratch, showWarnings = FALSE, recursive = TRUE)

client_factory <- function() {
  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  codeagent::codeagent_client(
    chat            = chat,
    register_tools  = TRUE,        # bring codeagent's full built-in toolset
    permission_mode = "bypass",    # Phase A: no approval bridge → auto-run (see warning above)
    cwd             = scratch
  )
}

handler <- make_codeagent_handler(client_factory)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "codeagent backend (full tools)"
)
server <- function(input, output, session) {
  # prewarm = TRUE: build the codeagent client in the background right after the
  # UI loads (codeagent_client construction ~a few seconds) so the first message
  # isn't blocked by it. A brief cold-start "warming" indicator shows meanwhile.
  assistantUIServer("chat", handler = handler, prewarm = TRUE)
}
shinyApp(ui, server)
