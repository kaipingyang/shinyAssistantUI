# examples/27_codeagent_backend.R
# ─────────────────────────────────────────────────────────────────────────────
# codeagent as the backend engine (Plan 51, Phase B) — FULL built-in tools.
#
# make_codeagent_handler() drives a full `codeagent` agent. With
# `register_tools = TRUE` (default) codeagent brings its whole toolset:
# run_r (executes R — plots stream back INLINE as images), Read/Glob/Grep/LS,
# WebFetch/WebSearch, Write/Edit/Bash, etc. Ask it to "plot mtcars hp vs mpg and
# run it" and the chart appears in the conversation.
#
# PERMISSIONS (Phase B — the in-app approval card is now wired):
#   * permission_mode = "default" (this example): reads + WebFetch/WebSearch
#     auto-allow; run_r / Write / Bash pop an APPROVAL CARD in the chat — click
#     Approve to run, Deny to skip. This is the safe, supervised default.
#   * permission_mode = "bypassPermissions": everything auto-runs UNSUPERVISED
#     (run_r, Bash, Write...) with no prompts. Trusted, throwaway dirs only.
#   A scratch cwd keeps the agent's file operations contained either way.
#   (Note: only approve/deny is supported for codeagent tools — argument editing
#   is a Claude-only feature.)
#
# For the *embed-your-own-domain-tools* pattern (no coding tools), instead use
# codeagent_client(register_tools = FALSE) and register your tools on the chat
# (see the spike examples/codeagent-backend-spike.R).
#
# PREREQUISITES: `codeagent` installed; repo-root .Renviron with
#   OPENAI_BASE_URL / OPENAI_MODEL / OPENAI_API_KEY (as in examples/09,10).
#
# RUN:  shiny::runApp("examples/27_codeagent_backend.R")
#   try: "Plot mtcars hp vs mpg with ggplot2 and run it"   → approve → inline chart
#        "What is 12 * 13?"                                 → approve run_r → answer
#        "Write a file hello.txt containing 'hi'"           → approval card (Deny to skip)
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
    permission_mode = "default",   # Phase B: write/execute tools -> approval card
    cwd             = scratch
  )
}

# permission_mode = "default": the handler installs codeagent's permission gate
# and bridges it to the in-app approval card (Approve/Deny). Reads auto-allow.
handler <- make_codeagent_handler(client_factory, permission_mode = "default")

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100vh"),
  title = "codeagent backend (full tools)"
)
server <- function(input, output, session) {
  # prewarm = TRUE: build the codeagent client in the background right after the
  # UI loads (codeagent_client construction ~a few seconds) so the first message
  # isn't blocked by it. A brief cold-start "warming" indicator shows meanwhile.
  assistantUIServer(
    "chat", handler = handler,
    prewarm         = TRUE,
    warming_label   = "Starting codeagent\u2026",
    welcome_message = "codeagent is ready \u2014 ask it to run R, make plots, or search the web."
  )
}
shinyApp(ui, server)
