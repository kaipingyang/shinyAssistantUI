// @vitest-environment jsdom
// Plan 56 — FileAttachmentAdapter (PDF/Excel → base64) + extractAttachments file mapping.
import { describe, it, expect } from "vitest";
import { FileAttachmentAdapter, FILE_ACCEPT } from "./file-attachment-adapter";
import { extractAttachments } from "./helpers";

describe("FileAttachmentAdapter", () => {
  it("accepts PDF + Excel MIME/extensions", () => {
    expect(FILE_ACCEPT).toContain("application/pdf");
    expect(FILE_ACCEPT).toContain("spreadsheetml.sheet");
    expect(FILE_ACCEPT).toContain(".xlsx");
  });

  it("add() yields a pending file attachment", async () => {
    const a = new FileAttachmentAdapter();
    const file = new File(["hello"], "report.pdf", { type: "application/pdf" });
    const p = await a.add({ file });
    expect(p.type).toBe("file");
    expect(p.name).toBe("report.pdf");
    expect(p.contentType).toBe("application/pdf");
    expect(p.status).toEqual({ type: "requires-action", reason: "composer-send" });
  });

  it("send() produces a base64 data-URL file content part", async () => {
    const a = new FileAttachmentAdapter();
    const file = new File(["hello"], "report.pdf", { type: "application/pdf" });
    const pending = await a.add({ file });
    const done: any = await a.send(pending as any);
    expect(done.status).toEqual({ type: "complete" });
    expect(done.content).toHaveLength(1);
    const part = done.content[0];
    expect(part.type).toBe("file");
    expect(part.mimeType).toBe("application/pdf");
    expect(part.data).toMatch(/^data:application\/pdf;base64,/);
  });
});

describe("extractAttachments — file mapping (Plan 56)", () => {
  it("maps a file attachment to {type:file, data, contentType}", () => {
    const { attachmentData } = extractAttachments({
      attachments: [
        {
          name: "grades.xlsx",
          contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          content: [
            {
              type: "file",
              data: "data:application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;base64,AAAA",
              mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            },
          ],
        },
      ],
    });
    expect(attachmentData).toHaveLength(1);
    expect(attachmentData[0].type).toBe("file");
    expect(attachmentData[0].name).toBe("grades.xlsx");
    expect(attachmentData[0].data).toMatch(/^data:application\/vnd.*base64,AAAA$/);
    expect(attachmentData[0].contentType).toContain("spreadsheetml.sheet");
  });
});
