// Downscaling image attachment adapter.
//
// Why: the ClaudeAgentSDK feeds the `claude` CLI a single stream-json line over
// stdin. A multi-MB base64 image makes that line so long the CLI's reader chokes
// and the turn hangs forever (empirically: a ~4MB PNG hangs; a tiny one replies).
// It also matches Anthropic's guidance (downscale to a ~1568px max edge).
//
// So: like SimpleImageAttachmentAdapter, but `send()` resizes the image to a safe
// max dimension and keeps the encoded size well under the CLI's line limit
// (PNG when small enough to preserve transparency, else JPEG at decreasing quality).
import {
  SimpleImageAttachmentAdapter,
  type AttachmentAdapter,
  type PendingAttachment,
  type CompleteAttachment,
} from "@assistant-ui/react";

const MAX_EDGE = 1280; // downscale large screenshots (well within Anthropic's 1568 max)
// Keep the encoded image well UNDER the ClaudeAgentSDK stdin truncation threshold
// (~220KB pipe buffer — larger single-line messages are truncated and hang the CLI).
const MAX_BYTES = 150_000;

const fileToDataURL = (file: Blob): Promise<string> =>
  new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result as string);
    r.onerror = reject;
    r.readAsDataURL(file);
  });

// approximate decoded byte size of a data: URL (base64 is ~4/3 the bytes)
const dataUrlBytes = (dataUrl: string): number => {
  const comma = dataUrl.indexOf(",");
  return comma < 0 ? dataUrl.length : Math.floor((dataUrl.length - comma - 1) * 0.75);
};

async function resizeImageToDataURL(file: File): Promise<string> {
  // SVG / non-raster or environments without canvas: fall back to raw encoding.
  if (typeof document === "undefined" || !file.type.startsWith("image/")) {
    return fileToDataURL(file);
  }
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const im = new Image();
      im.onload = () => resolve(im);
      im.onerror = reject;
      im.src = url;
    });
    const w0 = img.naturalWidth || img.width;
    const h0 = img.naturalHeight || img.height;
    if (!w0 || !h0) return fileToDataURL(file);
    const scale = Math.min(1, MAX_EDGE / Math.max(w0, h0));
    const w = Math.max(1, Math.round(w0 * scale));
    const h = Math.max(1, Math.round(h0 * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) return fileToDataURL(file);
    ctx.drawImage(img, 0, 0, w, h);
    // PNG first (lossless, keeps transparency); fall back to JPEG if too big.
    let dataUrl = canvas.toDataURL("image/png");
    if (dataUrlBytes(dataUrl) > MAX_BYTES) {
      let quality = 0.85;
      dataUrl = canvas.toDataURL("image/jpeg", quality);
      while (dataUrlBytes(dataUrl) > MAX_BYTES && quality > 0.4) {
        quality -= 0.15;
        dataUrl = canvas.toDataURL("image/jpeg", quality);
      }
    }
    return dataUrl;
  } catch {
    return fileToDataURL(file);
  } finally {
    URL.revokeObjectURL(url);
  }
}

export class ResizingImageAttachmentAdapter implements AttachmentAdapter {
  accept = "image/*";
  private inner = new SimpleImageAttachmentAdapter();

  add(state: { file: File }) {
    return this.inner.add(state);
  }
  remove(attachment: PendingAttachment) {
    return this.inner.remove(attachment);
  }
  async send(attachment: PendingAttachment): Promise<CompleteAttachment> {
    const image = await resizeImageToDataURL(attachment.file);
    return {
      ...attachment,
      status: { type: "complete" },
      content: [{ type: "image", image }],
    } as CompleteAttachment;
  }
}
