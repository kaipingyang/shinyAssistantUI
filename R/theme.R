#' Construct a theme for the assistant UI
#'
#' Builds a named list of theme tokens for [assistantUIServer()]'s `theme`
#' argument. Colors may be given as any color R understands (hex like
#' `"#2563eb"`, named colors like `"steelblue"`, or `rgb()` strings) — these are
#' converted to `#rrggbb`. CSS color functions (`hsl()`, `oklch()`, `lab()`, …)
#' and `var(...)` are passed through unchanged. Each value is injected verbatim
#' as a CSS custom property, so it must be a complete CSS color: for HSL, wrap
#' the components in `hsl(...)` (e.g. `hsl(217 91% 60%)`) — a bare `"217 91% 60%"`
#' is not a valid CSS value and is rejected.
#'
#' assistant-ui uses shadcn-style semantic color tokens. Each token has a
#' matching `*_foreground` companion used for text drawn on top of it.
#'
#' @param background,foreground Base surface color and default text color.
#' @param primary,primary_foreground Primary accent (send button, user bubble).
#' @param secondary,secondary_foreground Secondary surfaces.
#' @param accent,accent_foreground Hover/active highlight color.
#' @param muted,muted_foreground Muted surfaces and secondary text.
#' @param destructive,destructive_foreground Error/danger color.
#' @param card,card_foreground Card surfaces (e.g. tool result cards).
#' @param popover,popover_foreground Popover/menu surfaces.
#' @param border,input Border color and input border color.
#' @param ring Focus ring color.
#' @param radius Corner radius as a CSS length (e.g. `"0.5rem"`, `"8px"`).
#'   Passed through verbatim (not a color).
#'
#' @return A named list of CSS-ready theme tokens, suitable for the `theme`
#'   argument of [assistantUIServer()].
#'
#' @examples
#' assistant_theme(primary = "#2563eb", radius = "0.75rem")
#' assistant_theme(background = "#0b1020", foreground = "#e5e7eb")
#'
#' @export
assistant_theme <- function(background = NULL, foreground = NULL,
                            primary = NULL, primary_foreground = NULL,
                            secondary = NULL, secondary_foreground = NULL,
                            accent = NULL, accent_foreground = NULL,
                            muted = NULL, muted_foreground = NULL,
                            destructive = NULL, destructive_foreground = NULL,
                            card = NULL, card_foreground = NULL,
                            popover = NULL, popover_foreground = NULL,
                            border = NULL, input = NULL, ring = NULL,
                            radius = NULL) {
  raw <- list(
    background             = background,
    foreground             = foreground,
    primary                = primary,
    primary_foreground     = primary_foreground,
    secondary              = secondary,
    secondary_foreground   = secondary_foreground,
    accent                 = accent,
    accent_foreground      = accent_foreground,
    muted                  = muted,
    muted_foreground       = muted_foreground,
    destructive            = destructive,
    destructive_foreground = destructive_foreground,
    card                   = card,
    card_foreground        = card_foreground,
    popover                = popover,
    popover_foreground     = popover_foreground,
    border                 = border,
    input                  = input,
    ring                   = ring,
    radius                 = radius
  )
  .normalize_theme(raw)
}

# 把单个颜色规整成一个 CSS 可用的颜色值(供注入 --primary 等 Tailwind v4 token)。
# - 已是 CSS 颜色函数/hex(#、rgb、hsl、oklch、oklab、var())→ 原样返回(幂等)。
# - 其余(R 命名色等)交给 grDevices::col2rgb 解析后转为 #rrggbb。
.color_to_css <- function(color) {
  if (!is.character(color) || length(color) != 1L || is.na(color)) {
    stop("theme color must be a single non-NA string.")
  }
  if (grepl("^\\s*(#|rgb|rgba|hsl|hsla|oklch|oklab|lab|lch|color|var\\()",
            color, ignore.case = TRUE)) {
    return(trimws(color))
  }
  rgb <- tryCatch(
    grDevices::col2rgb(color)[, 1],
    error = function(e) stop(sprintf(
      paste0("invalid theme color \"%s\": use a hex (\"#2563eb\"), named (\"steelblue\"), ",
             "rgb()/hsl()/oklch() color, or var(...). For HSL, wrap the components in ",
             "hsl(...), e.g. hsl(217 91%% 60%%)."),
      color), call. = FALSE)
  )
  sprintf("#%02x%02x%02x", rgb[[1]], rgb[[2]], rgb[[3]])
}

# 归一化整个 theme 列表:去 NULL,radius 透传,其余颜色规整为 CSS 颜色。
# 幂等:重复调用不改变结果。接受 assistant_theme() 输出或用户手写的命名列表。
.normalize_theme <- function(theme) {
  if (is.null(theme) || length(theme) == 0L) return(NULL)
  if (!is.list(theme) || is.null(names(theme))) {
    stop("`theme` must be a named list (see assistant_theme()).")
  }
  theme <- theme[!vapply(theme, is.null, logical(1))]
  if (length(theme) == 0L) return(NULL)
  out <- lapply(names(theme), function(k) {
    v <- theme[[k]]
    if (identical(k, "radius")) return(as.character(v))  # 长度值,非颜色
    .color_to_css(as.character(v))
  })
  names(out) <- names(theme)
  out
}
