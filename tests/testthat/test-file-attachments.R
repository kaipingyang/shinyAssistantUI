# Plan 56 — PDF native document block + Excel (readxl) extraction.

test_that(".claude_document_block: data URL → base64 document block", {
  f <- shinyAssistantUI:::.claude_document_block
  b <- f("data:application/pdf;base64,QUJDRA==")
  expect_identical(b$type, "document")
  expect_identical(b$source$type, "base64")
  expect_identical(b$source$media_type, "application/pdf")
  expect_identical(b$source$data, "QUJDRA==")
})

test_that(".claude_document_block: non-data-URL → url source", {
  f <- shinyAssistantUI:::.claude_document_block
  b <- f("https://example.com/x.pdf")
  expect_identical(b$type, "document")
  expect_identical(b$source$type, "url")
})

test_that(".att_is_pdf detects pdf by contentType or name, not spreadsheets/images", {
  f <- shinyAssistantUI:::.att_is_pdf
  expect_true(f(list(type = "file", contentType = "application/pdf")))
  expect_true(f(list(type = "file", name = "report.PDF")))
  expect_false(f(list(type = "image", contentType = "image/png")))
  expect_false(f(list(type = "file",
                      contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")))
  expect_false(f(list(type = "text")))
})

test_that(".claude_message_content: doc-only omits empty text block; text+doc keeps order", {
  f <- shinyAssistantUI:::.claude_message_content
  out <- f("", list(), list("data:application/pdf;base64,QUJD"))   # doc-only
  expect_length(out, 1L)
  expect_identical(out[[1]]$type, "document")
  out2 <- f("hi", list(), list("data:application/pdf;base64,QUJD"))  # text + doc
  expect_length(out2, 2L)
  expect_identical(out2[[1]]$type, "text")
  expect_identical(out2[[2]]$type, "document")
  expect_identical(f("hello", list(), list()), "hello")             # nothing → plain string
})

test_that(".xlsx_to_markdown: readxl → markdown table with sheet header", {
  skip_if_not_installed("writexl"); skip_if_not_installed("readxl"); skip_if_not_installed("base64enc")
  f <- shinyAssistantUI:::.xlsx_to_markdown
  tf <- tempfile(fileext = ".xlsx")
  writexl::write_xlsx(list(Data = data.frame(name = c("Alice", "Bob"), score = c(91L, 88L))), tf)
  b64 <- base64enc::base64encode(tf); unlink(tf)
  md <- f(paste0("data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,", b64),
          "grades.xlsx")
  expect_match(md, "Sheet: Data", fixed = TRUE)
  expect_match(md, "| name | score |", fixed = TRUE)
  expect_match(md, "Alice", fixed = TRUE)
  expect_match(md, "91", fixed = TRUE)
  expect_match(md, "<attachment name=grades.xlsx", fixed = TRUE)
})

test_that(".xlsx_to_markdown: column cap truncates wide sheets", {
  skip_if_not_installed("writexl"); skip_if_not_installed("base64enc")
  f <- shinyAssistantUI:::.xlsx_to_markdown
  wide <- as.data.frame(matrix(seq_len(50), nrow = 1)); names(wide) <- paste0("c", seq_len(50))
  tf <- tempfile(fileext = ".xlsx"); writexl::write_xlsx(list(S = wide), tf)
  b64 <- base64enc::base64encode(tf); unlink(tf)
  md <- f(paste0("data:application/vnd.ms-excel;base64,", b64), "w.xlsx", max_cols = 10L)
  expect_match(md, "cols truncated", fixed = TRUE)
})

test_that(".extract_file_text: unknown binary → placeholder", {
  f <- shinyAssistantUI:::.extract_file_text
  expect_match(
    f(list(type = "file", name = "a.bin", contentType = "application/octet-stream")),
    "binary content not directly readable", fixed = TRUE
  )
})
