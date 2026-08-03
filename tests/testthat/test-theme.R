test_that(".color_to_css converts named colors to hex", {
  expect_equal(shinyAssistantUI:::.color_to_css("white"), "#ffffff")
  expect_equal(shinyAssistantUI:::.color_to_css("black"), "#000000")
  expect_equal(shinyAssistantUI:::.color_to_css("red"), "#ff0000")
})

test_that(".color_to_css passes through CSS color functions/hex", {
  expect_equal(shinyAssistantUI:::.color_to_css("#2563eb"), "#2563eb")
  expect_equal(shinyAssistantUI:::.color_to_css("rgb(1,2,3)"), "rgb(1,2,3)")
  expect_equal(shinyAssistantUI:::.color_to_css("oklch(0.6 0.1 250)"), "oklch(0.6 0.1 250)")
  expect_equal(shinyAssistantUI:::.color_to_css("  hsl(210 90% 50%)  "), "hsl(210 90% 50%)")
})

test_that(".color_to_css rejects invalid input", {
  expect_error(shinyAssistantUI:::.color_to_css(c("a", "b")))
  expect_error(shinyAssistantUI:::.color_to_css(NA_character_))
  expect_error(shinyAssistantUI:::.color_to_css("not-a-color"))
})

test_that(".color_to_css: bare HSL components are rejected with a helpful hsl() hint", {
  # Bare shadcn-style "H S% L%" is NOT a valid CSS value here (injected raw as
  # `--primary: <value>`), so it must error clearly and point at hsl(...).
  expect_error(shinyAssistantUI:::.color_to_css("217 91% 60%"), "hsl", ignore.case = TRUE)
  # The wrapped form is the supported way and passes through unchanged.
  expect_equal(shinyAssistantUI:::.color_to_css("hsl(217 91% 60%)"), "hsl(217 91% 60%)")
})

test_that("assistant_theme drops NULLs and normalizes colors", {
  th <- assistant_theme(primary = "#2563eb", radius = "0.75rem")
  expect_named(th, c("primary", "radius"))
  expect_equal(th$primary, "#2563eb")
  expect_equal(th$radius, "0.75rem")  # radius passes through unchanged
})

test_that("assistant_theme handles foreground companion tokens", {
  th <- assistant_theme(primary = "steelblue", primary_foreground = "white")
  expect_named(th, c("primary", "primary_foreground"))
  expect_equal(th$primary_foreground, "#ffffff")
})

test_that(".normalize_theme is idempotent and drops NULL/empty", {
  th <- assistant_theme(primary = "#2563eb")
  expect_identical(shinyAssistantUI:::.normalize_theme(th), th)
  expect_null(shinyAssistantUI:::.normalize_theme(NULL))
  expect_null(shinyAssistantUI:::.normalize_theme(list()))
  expect_null(shinyAssistantUI:::.normalize_theme(list(primary = NULL)))
})

test_that(".normalize_theme accepts hand-written named list", {
  th <- shinyAssistantUI:::.normalize_theme(list(primary = "#000000", radius = "8px"))
  expect_equal(th$primary, "#000000")
  expect_equal(th$radius, "8px")
})

test_that(".normalize_theme errors on unnamed list", {
  expect_error(shinyAssistantUI:::.normalize_theme(list("#fff")), "named list")
})
