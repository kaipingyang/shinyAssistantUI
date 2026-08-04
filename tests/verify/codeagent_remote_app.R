# Fixture: a real assistantUIServer app driven by the OUT-OF-PROCESS remote
# handler. Deliberately does NOT library(ellmer/codeagent) — the MAIN app process
# must stay curl-free; only the spawned worker loads them. Writes its own
# loadedNamespaces() to a fixed file so the headless verify can assert isolation.
library(shiny)
library(shinyAssistantUI)   # Imports have no curl/ellmer

NEWLIB   <- "/usrfiles/shared-projects/users/kaiping_yang/Rlibs/codeagent/R-4.4"
RENVIRON <- normalizePath(".Renviron", mustWork = FALSE)
NSFILE   <- "/tmp/sau_app_ns.txt"
scratch  <- file.path(tempdir(), "caremote"); dir.create(scratch, showWarnings = FALSE, recursive = TRUE)

handler <- make_codeagent_remote_handler(
  config          = list(cwd = scratch),
  libpath         = NEWLIB,
  renviron        = RENVIRON,
  permission_mode = "default")

ui <- assistantUIPage(assistantUIOutput("chat", height = "100vh"),
                      title = "codeagent (out-of-process)")
server <- function(input, output, session) {
  observe({ invalidateLater(1500); try(writeLines(loadedNamespaces(), NSFILE), silent = TRUE) })
  assistantUIServer("chat", handler = handler, prewarm = TRUE,
                    warming_label   = "Starting codeagent worker\u2026",
                    welcome_message = "Out-of-process codeagent ready.")
}
shinyApp(ui, server)
