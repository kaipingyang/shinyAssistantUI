#' Construct a theme for the assistant UI
#'
#' Builds a named list of theme tokens for [assistantUIServer()]'s `theme`
#' argument. Colors may be given in any format R understands (hex like
#' `"#2563eb"`, named colors like `"steelblue"`, or `rgb()` strings) and are
#' converted to the HSL-component format assistant-ui expects
#' (`"H S% L%"`, e.g. `"217 91% 60%"`). Values that are already in
#' HSL-component form are passed through unchanged.
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

# 把单个颜色转成 assistant-ui 需要的 HSL 分量字符串 "H S% L%"。
# - 已是 HSL 分量（"217 91% 60%"）→ 原样返回（幂等，支持用户直接传分量）。
# - 其余交给 grDevices::col2rgb 解析（hex / 命名色 / rgb() 均可），再 RGB→HSL。
.color_to_hsl_components <- function(color) {
  if (!is.character(color) || length(color) != 1L || is.na(color)) {
    stop("theme color must be a single non-NA string.")
  }
  # 已是 HSL 分量:两个百分比 + 前导数字
  if (grepl("^\\s*[0-9.]+\\s+[0-9.]+%\\s+[0-9.]+%\\s*$", color)) {
    return(trimws(color))
  }
  rgb <- grDevices::col2rgb(color)[, 1] / 255
  r <- rgb[[1]]; g <- rgb[[2]]; b <- rgb[[3]]
  mx <- max(r, g, b); mn <- min(r, g, b)
  l <- (mx + mn) / 2
  if (mx == mn) {
    h <- 0; s <- 0                       # 灰阶:无色相无饱和
  } else {
    d <- mx - mn
    s <- if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn)
    h <- if (mx == r)      ((g - b) / d) %% 6
         else if (mx == g) ((b - r) / d) + 2
         else              ((r - g) / d) + 4
    h <- h * 60
    if (h < 0) h <- h + 360
  }
  sprintf("%.0f %.1f%% %.1f%%", h, s * 100, l * 100)
}

# 归一化整个 theme 列表:去 NULL,radius 透传,其余颜色转 HSL 分量。
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
    .color_to_hsl_components(as.character(v))
  })
  names(out) <- names(theme)
  out
}
