# Capture a plot as a PNG data URI (for `on_image()`)

Convenience helper for the chart/plot path of a chat handler: renders a
plotting expression to an off-screen PNG and returns it as a
`data:image/png;base64,...` string, ready to hand to the `on_image()`
callback so the plot appears inline in the conversation. This is the
recommended way to show charts (ggplot2, lattice, or base graphics)
inline — R's own plotting is used, and only an image is sent to the
browser (no client-side charting library is bundled).

## Usage

``` r
plot_data_uri(expr, width = 640, height = 400, res = 96)
```

## Arguments

  - expr:
    
    A plotting expression or a printable plot object (evaluated once,
    inside the device).

  - width, height:
    
    Image size in pixels. Defaults 640x400.

  - res:
    
    Nominal resolution in ppi (affects text/line scaling). Default 96.

## Value

A single string `"data:image/png;base64,..."`.

## Details

`expr` is evaluated lazily inside the PNG graphics device:

  - **base graphics** (e.g. `plot(...)`, `hist(...)`) draw during
    evaluation — pass the plotting call directly.

  - **ggplot2 / lattice** objects only draw when printed — pass the
    object (e.g. `ggplot(df, aes(x, y)) + geom_point()`); it is
    auto-printed.

The graphics device is always closed, even if `expr` errors.

## See also

`assistantUIServer()` for the `on_image()` callback.

## Examples

``` r
if (FALSE) { # \dontrun{
assistantUIServer("chat", handler = function(message, on_chunk, on_done, on_image, ...) {
  on_chunk("Here's the distribution:\n")
  on_image(plot_data_uri(hist(rnorm(1000))))                       # base graphics
  # on_image(plot_data_uri(ggplot2::qplot(speed, dist, data = cars)))  # ggplot2
  on_done()
})
} # }
```
