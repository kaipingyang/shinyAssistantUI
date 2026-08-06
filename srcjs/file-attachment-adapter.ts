// Plan 56 — generic binary file attachment adapter (PDF + Excel).
//
// Reads the file as a base64 data URL and ships it to R WITHOUT any client-side parsing
// (keeps the bundle small — no pdf.js/SheetJS). R then routes by contentType:
//   • application/pdf  → Claude native document block (.claude_document_block)
//   • xlsx/xls         → readxl → markdown table (backend-agnostic)
// Word/PPT are deliberately out of scope (Plan 56 — poor ROI); not accepted here.
import type {
  AttachmentAdapter,
  PendingAttachment,
  CompleteAttachment,
} from "@assistant-ui/react";

const fileToDataURL = (file: Blob): Promise<string> =>
  new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result as string);
    r.onerror = reject;
    r.readAsDataURL(file);
  });

// MIME types + extension fallbacks (some OSes hand the picker an empty MIME for .xlsx).
export const FILE_ACCEPT = [
  "application/pdf",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", // .xlsx
  "application/vnd.ms-excel", // .xls
  ".pdf",
  ".xlsx",
  ".xls",
].join(",");

export class FileAttachmentAdapter implements AttachmentAdapter {
  accept = FILE_ACCEPT;

  async add(state: { file: File }): Promise<PendingAttachment> {
    return {
      id: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
      type: "file",
      name: state.file.name,
      contentType: state.file.type || "application/octet-stream",
      file: state.file,
      status: { type: "requires-action", reason: "composer-send" },
    } as PendingAttachment;
  }

  async remove(): Promise<void> {}

  async send(attachment: PendingAttachment): Promise<CompleteAttachment> {
    const dataUrl = await fileToDataURL(attachment.file);
    return {
      ...attachment,
      status: { type: "complete" },
      // extractAttachments() picks up a `file` content part via {data, mimeType}
      content: [
        { type: "file", data: dataUrl, mimeType: attachment.contentType } as never,
      ],
    } as CompleteAttachment;
  }
}
