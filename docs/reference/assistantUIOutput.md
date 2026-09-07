# AI Assistant Chat UI Output

Creates a Shiny output placeholder for the assistant UI chat component.

## Usage

``` r
assistantUIOutput(
  outputId,
  width = "100%",
  height = "600px",
  modal = FALSE,
  ...
)
```

## Arguments

  - outputId:
    
    Output variable to read from.

  - width, height:
    
    Width and height of the widget (CSS values).

  - modal:
    
    Logical. If `TRUE`, sizes the widget for floating modal use.

  - ...:
    
    Additional attributes passed to the container `<div>`.

## Value

An HTML output element with its JS/CSS dependency attached.

## Details

The component is a native Shiny output binding (not an htmlwidget): a
plain `<div class="assistantUI assistantUI-output">` plus an
`htmltools::htmlDependency()` that provides the bundled JS/CSS. The
React app mounts into the div when the server sends its value via
`renderAssistantUI()`; all streaming/interaction then flows over
`session$sendCustomMessage()` and `Shiny.setInputValue()`.
