# Construct a theme for the assistant UI

Builds a named list of theme tokens for `assistantUIServer()`'s `theme`
argument. Colors may be given as any color R understands (hex like
`"#2563eb"`, named colors like `"steelblue"`, or `rgb()` strings) —
these are converted to `#rrggbb`. CSS color functions (`hsl()`,
`oklch()`, `lab()`, …) and `var(...)` are passed through unchanged. Each
value is injected verbatim as a CSS custom property, so it must be a
complete CSS color: for HSL, wrap the components in `hsl(...)` (e.g.
`hsl(217 91% 60%)`) — a bare `"217 91% 60%"` is not a valid CSS value
and is rejected.

## Usage

``` r
assistant_theme(
  background = NULL,
  foreground = NULL,
  primary = NULL,
  primary_foreground = NULL,
  secondary = NULL,
  secondary_foreground = NULL,
  accent = NULL,
  accent_foreground = NULL,
  muted = NULL,
  muted_foreground = NULL,
  destructive = NULL,
  destructive_foreground = NULL,
  card = NULL,
  card_foreground = NULL,
  popover = NULL,
  popover_foreground = NULL,
  border = NULL,
  input = NULL,
  ring = NULL,
  radius = NULL
)
```

## Arguments

  - background, foreground:
    
    Base surface color and default text color.

  - primary, primary\_foreground:
    
    Primary accent (send button, user bubble).

  - secondary, secondary\_foreground:
    
    Secondary surfaces.

  - accent, accent\_foreground:
    
    Hover/active highlight color.

  - muted, muted\_foreground:
    
    Muted surfaces and secondary text.

  - destructive, destructive\_foreground:
    
    Error/danger color.

  - card, card\_foreground:
    
    Card surfaces (e.g. tool result cards).

  - popover, popover\_foreground:
    
    Popover/menu surfaces.

  - border, input:
    
    Border color and input border color.

  - ring:
    
    Focus ring color.

  - radius:
    
    Corner radius as a CSS length (e.g. `"0.5rem"`, `"8px"`). Passed
    through verbatim (not a color).

## Value

A named list of CSS-ready theme tokens, suitable for the `theme`
argument of `assistantUIServer()`.

## Details

assistant-ui uses shadcn-style semantic color tokens. Each token has a
matching `*_foreground` companion used for text drawn on top of it.

## Examples

``` r
assistant_theme(primary = "#2563eb", radius = "0.75rem")
#> $primary
#> [1] "#2563eb"
#> 
#> $radius
#> [1] "0.75rem"
#> 
assistant_theme(background = "#0b1020", foreground = "#e5e7eb")
#> $background
#> [1] "#0b1020"
#> 
#> $foreground
#> [1] "#e5e7eb"
#> 
```
