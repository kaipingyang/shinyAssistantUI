# Create a standalone assistant UI page

Creates a full-height Shiny page for assistant-ui widgets. The page adds
an `aui-page` body class, establishes the `html`/`body` height chain,
and suppresses Bootstrap by default so its global styles do not override
the widget's Tailwind/shadcn styles.

## Usage

``` r
assistantUIPage(..., title = NULL, padding = 0, suppress_bootstrap = TRUE)
```

## Arguments

  - ...:
    
    Contents of the document body. Typically one
    `assistantUIOutput("chat", height = "100%")`.

  - title:
    
    Optional browser page title.

  - padding:
    
    CSS padding applied to the page body. Must be a single CSS unit;
    defaults to `0`.

  - suppress\_bootstrap:
    
    Logical. If `TRUE` (the default), suppress any Bootstrap dependency
    contributed by descendants. Set to `FALSE` only when the page
    intentionally combines assistant-ui with Bootstrap components.

## Value

An HTML tag list suitable for the `ui` argument of `shiny::shinyApp()`.

## Details

Use this for a standalone assistant application. When embedding
`assistantUIOutput()` in an existing `bslib` or Bootstrap page, use that
page's layout functions instead.

## Examples

``` r
assistantUIPage(
  assistantUIOutput("chat", height = "100%")
)
#> <body class="aui-page html-fill-container">
#>   <div id="chat" class="assistantUI assistantUI-output" style="width:100%;height:100%;"></div>
#> </body>
```
