# Render an Assistant UI Widget

Server-side render function for `assistantUIOutput()`. Typically used
inside `assistantUIServer()` rather than called directly. Sends
`{inputId, config}` to the client-side output binding, which mounts the
React app.

## Usage

``` r
renderAssistantUI(config = list(), outputId = NULL)
```

## Arguments

  - config:
    
    Optional named list of configuration options.

  - outputId:
    
    The output ID used in `assistantUIOutput()`. The widget uses this to
    derive the Shiny input name that carries user messages.

## Value

A render function suitable for assigning to `output[[outputId]]`.
