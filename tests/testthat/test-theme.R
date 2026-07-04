test_that(".color_to_hsl_components converts hex correctly", {
  # #2563eb ≈ hsl(221, 83%, 53%)
  out <- shinyAssistantUI:::.color_to_hsl_components("#2563eb")
  parts <- as.numeric(strsplit(gsub("%", "", out), " ")[[1]])
  expect_equal(parts[1], 221, tolerance = 1)   # hue
  expect_equal(parts[2], 83,  tolerance = 1.5) # saturation
  expect_equal(parts[3], 53,  tolerance = 1.5) # lightness
})

test_that(".color_to_hsl_components handles named colors", {
  # white = 0 0% 100%
  expect_equal(shinyAssistantUI:::.color_to_hsl_components("white"), "0 0.0% 100.0%")
  # black = 0 0% 0%
  expect_equal(shinyAssistantUI:::.color_to_hsl_components("black"), "0 0.0% 0.0%")
})

test_that(".color_to_hsl_components is idempotent for HSL-component input", {
  expect_equal(shinyAssistantUI:::.color_to_hsl_components("217 91% 60%"), "217 91% 60%")
  expect_equal(shinyAssistantUI:::.color_to_hsl_components("  240 5.9% 10%  "), "240 5.9% 10%")
})

test_that(".color_to_hsl_components rejects invalid input", {
  expect_error(shinyAssistantUI:::.color_to_hsl_components(c("a", "b")))
  expect_error(shinyAssistantUI:::.color_to_hsl_components(NA_character_))
  expect_error(shinyAssistantUI:::.color_to_hsl_components("not-a-color"))
})

test_that("assistant_theme drops NULLs and converts colors", {
  th <- assistant_theme(primary = "#2563eb", radius = "0.75rem")
  expect_named(th, c("primary", "radius"))
  expect_match(th$primary, "^[0-9]+ [0-9.]+% [0-9.]+%$")
  expect_equal(th$radius, "0.75rem")  # radius passes through unchanged
})

test_that("assistant_theme handles foreground companion tokens", {
  th <- assistant_theme(primary = "steelblue", primary_foreground = "white")
  expect_named(th, c("primary", "primary_foreground"))
  expect_equal(th$primary_foreground, "0 0.0% 100.0%")
})

test_that(".normalize_theme is idempotent and drops NULL/empty", {
  th <- assistant_theme(primary = "#2563eb")
  expect_identical(shinyAssistantUI:::.normalize_theme(th), th)  # 二次归一化不变
  expect_null(shinyAssistantUI:::.normalize_theme(NULL))
  expect_null(shinyAssistantUI:::.normalize_theme(list()))
  expect_null(shinyAssistantUI:::.normalize_theme(list(primary = NULL)))
})

test_that(".normalize_theme accepts hand-written named list", {
  th <- shinyAssistantUI:::.normalize_theme(list(primary = "#000000", radius = "8px"))
  expect_equal(th$primary, "0 0.0% 0.0%")
  expect_equal(th$radius, "8px")
})

test_that(".normalize_theme errors on unnamed list", {
  expect_error(shinyAssistantUI:::.normalize_theme(list("#fff")), "named list")
})
