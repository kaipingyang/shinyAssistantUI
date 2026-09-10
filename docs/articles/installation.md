# Installation

## The R package installation model

The upstream assistant-ui installation guide creates or modifies a React
application with its CLI, shadcn registry, npm dependencies, API route,
and runtime provider. `shinyAssistantUI` adapts that stack at the R
package boundary instead of asking every Shiny user to rebuild it.

A normal package installation already contains:

  - assistant-ui’s React Web runtime and the project’s custom
    `ExternalStoreRuntime`;
  - the vendored thread, thread-list, modal, attachment, tool, Markdown,
    and composer components;
  - React, Base UI, Lexical, Markdown, syntax-highlighting, and styling
    code;
  - compiled JavaScript, CSS, and KaTeX assets under `inst/www`.

The browser surface mounts through a native Shiny output binding with an
`htmltools::htmlDependency()`; it is not an htmlwidgets widget.

Consequently, **package users do not need Node.js, npm, the assistant-ui
CLI, shadcn, Next.js, or Vite**. Those are maintainer/contributor tools,
not application prerequisites.

## Install the core package

This development site is built from the `dev` branch. Install that
branch explicitly to match the published documentation:

``` r
install.packages("remotes")
remotes::install_github(
  "kaipingyang/shinyAssistantUI",
  ref = "dev"
)
```

GitHub’s default branch is `main`, so omitting `ref` resolves to `main`
and may install code that differs from this site. Both `main` and `dev`
are floating branches. GitHub release tags may be available but can lag
either branch; there is currently no CRAN or R-universe release.

| Installation goal                | `ref`                          | Reproducibility |
| -------------------------------- | ------------------------------ | --------------- |
| Match this development site      | `"dev"`                        | Floating branch |
| Follow the default branch        | `"main"`                       | Floating branch |
| Reproduce a validated deployment | Release tag or full commit SHA | Pinned          |

For production, install a version your deployment has validated rather
than a moving branch:

``` r
remotes::install_github(
  "kaipingyang/shinyAssistantUI",
  ref = "<validated-tag-or-full-commit-sha>"
)
```

After installation, the browser assets should resolve from the installed
package:

``` r
library(shinyAssistantUI)

package_path <- normalizePath(find.package("shinyAssistantUI"))
package_version <- packageVersion("shinyAssistantUI")

package_path
package_version

stopifnot(
  nzchar(system.file(
    "www", "shinyAssistantUI.js",
    package = "shinyAssistantUI"
  ))
)
```

The package does not currently declare and test a minimum supported R
version. That is a real metadata and compatibility-matrix gap, so this
guide does not invent a version guarantee.

## Start without another AI package

The core package only requires an R handler. This deterministic example
verifies the UI and Shiny transport without an API key or optional
backend package:

``` r
library(shiny)
library(shinyAssistantUI)

ui <- assistantUIPage(
  assistantUIOutput("chat", height = "100%"),
  title = "Installation check"
)

server <- function(input, output, session) {
  assistantUIServer(
    "chat",
    handler = function(message, on_chunk, on_done, on_error) {
      on_chunk("shinyAssistantUI received: ")
      on_chunk(message)
      on_done()
    }
  )
}

shinyApp(ui, server)
```

`assistantUIServer()` is the local equivalent of the upstream backend
endpoint and runtime-provider wiring. Shiny inputs carry browser events
to R; the handler callbacks stream state back to the custom runtime.

## Add only the backend you use

Backend integrations are optional because the chat surface is
backend-agnostic.

| Route                      | Additional requirement                                   | What is installed separately                                                                                                             |
| -------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Custom R handler           | None beyond the core package                             | Your own HTTP/client code, if any                                                                                                        |
| ellmer                     | `ellmer` and the chosen provider setup                   | `install.packages("ellmer")`                                                                                                             |
| ClaudeAgentSDK             | ClaudeAgentSDK 0.2.5 or newer and a working `claude` CLI | The SDK package and CLI authentication                                                                                                   |
| codeagent, in process      | A compatible codeagent/ellmer installation               | Install from the source approved for the deployment                                                                                      |
| codeagent, isolated worker | Host packages: `callr`, `jsonlite`, `later`, `promises`  | Compatible worker library containing `codeagent`, `ellmer`, `jsonlite`, `later`, `promises`, and `curl`; pass its root through `libpath` |

The worker library’s provisioning and location are deployment-specific.
The public contract is only that `libpath` identifies a caller-provided
isolated R library root containing those compatible worker dependencies.

For ellmer:

``` r
install.packages("ellmer")

handler <- make_ellmer_handler(
  chat = function() ellmer::chat_openai()
)
```

Provider credentials belong to the provider, not to `shinyAssistantUI`.
Keep them in environment variables or an external secret manager, never
in committed R files. For example, an ellmer provider may read
`OPENAI_API_KEY` from the environment.

For ClaudeAgentSDK:

``` r
remotes::install_github("kaipingyang/ClaudeAgentSDK")
stopifnot(packageVersion("ClaudeAgentSDK") >= "0.2.5")

handler <- make_claude_handler()
```

Installing the R SDK does not install or authenticate the external
Claude CLI. The RStudio `claude_addin()` and `claude_workspace_addin()`
paths require both pieces.

## Use the packaged surfaces

The upstream page shows separate React wiring for Thread, ThreadList,
and AssistantModal. These are already exposed through the R API rather
than separate npm component installs:

``` r
# Inline thread with conversation navigation
assistantUIOutput("chat", height = "100%")
assistantUIServer("chat", handler = my_handler, show_thread_list = TRUE)

# Modal-capable package mode
assistantUIOutput("chat", modal = TRUE)
assistantUIServer("chat", handler = my_handler, modal = TRUE)
```

This means the absence of shadcn registry commands in the R installation
flow is not a missing Thread or modal feature. It is a packaging
decision: maintainers own and compile the component tree, while
application authors use the stable R entry points.

## Upstream-to-package audit

Each upstream installation step was checked against the current source
and package layout.

| Upstream step or feature                      | Current shinyAssistantUI evidence                                      | Assessment                                                        |
| --------------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `assistant-ui create` or `init`               | R package installation plus `assistantUIOutput()`                      | Replaced by R package architecture                                |
| React, shadcn, Base/Radix and Tailwind setup  | Components and dependencies are compiled into `inst/www`               | Intentional maintainer responsibility                             |
| `npm install @assistant-ui/react ...`         | Locked frontend build inputs produce the committed bundle              | Covered for users; npm is contributor-only                        |
| Add one API key                               | Core custom handler needs none; integrations use their own credentials | Backend-specific by design                                        |
| Create `/api/chat` with JavaScript AI SDK     | `assistantUIServer()` invokes an R handler                             | Replaced by Shiny transport architecture                          |
| Choose among JavaScript AI SDK providers      | ellmer, ClaudeAgentSDK, codeagent, or custom R code                    | Ecosystem adaptation; not one-to-one adapters                     |
| Wire Thread and ThreadList                    | `assistantUIOutput()` plus `show_thread_list = TRUE`                   | Covered                                                           |
| Wire AssistantModal                           | `modal = TRUE` package mode                                            | Covered                                                           |
| CRAN or R-universe distribution               | Not currently available                                                | Real distribution gap; use a validated Git tag or full commit SHA |
| Declared minimum R version                    | No tested minimum in `DESCRIPTION`                                     | Real metadata/test gap                                            |
| Remote codeagent with live host-defined tools | Worker cannot serialize a live ellmer chat                             | Real limitation; use in-process codeagent                         |

“Backend-agnostic” means the handler contract does not force a provider.
It does not mean every JavaScript AI SDK provider has a dedicated R
adapter or identical feature coverage.

## Build from source as a contributor

Only contributors changing `srcjs/` need the JavaScript toolchain. Use
the lockfile rather than the upstream `latest` commands:

``` bash
npm ci
npm run build
R CMD INSTALL --no-multiarch --with-keep.source .
```

The required order is build first, then install: the R installation
copies the newly compiled `inst/www` assets. The root `package.json` and
lockfile declare the same Node engine range: `^20.19.0 || ^22.12.0 ||
>=24.0.0`. Node 18 and Node 23 do not satisfy that range. These commands
are for source contributors, not ordinary package users.

For the architectural context, see the
[Overview](https://kaipingyang.github.io/shinyAssistantUI/articles/shiny-assistant-ui.md).
The source-by-source review status is recorded in [Upstream
documentation
alignment](https://kaipingyang.github.io/shinyAssistantUI/articles/upstream-alignment.md).
