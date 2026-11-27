// Byte-level metadata removal for Meet photos (Meet v5 design §2.7, §8.5).
//
// A phone writes where and when a picture was taken into the file itself: EXIF GPS in a JPEG's
// APP1, XMP packets, PNG text chunks, WebP EXIF and XMP chunks. A Meet photo is shown to
// strangers, so none of it may survive. Nothing here decodes or re-encodes pixels: the container
// is walked, only the blocks an image needs to be drawn are kept (an allowlist, so a private or
// future metadata chunk goes too), and the image data is copied exactly as it came.
//
// Refused outright: anything whose container cannot be walked to its end, and animation (an
// animated WebP or APNG), because a moderator approves the frame they see and nobody else would
// see only that frame.

export type ImageKind = "jpeg" | "png" | "webp";

export type StrippedImage = {
  kind: ImageKind;
  mime: "image/jpeg" | "image/png" | "image/webp";
  extension: "jpg" | "png" | "webp";
  width: number;
  height: number;
  bytes: Uint8Array;
};

export type MediaFailure = "bad_type" | "corrupt" | "animated";

export class MediaError extends Error {
  constructor(readonly reason: MediaFailure) {
    super(reason);
  }
}

const KINDS = {
  jpeg: { mime: "image/jpeg", extension: "jpg" },
  png: { mime: "image/png", extension: "png" },
  webp: { mime: "image/webp", extension: "webp" },
} as const;

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
// What a still PNG needs to be drawn as intended: the critical chunks, transparency and colour.
const PNG_KEEP = new Set([
  "IHDR",
  "PLTE",
  "IDAT",
  "IEND",
  "tRNS",
  "cHRM",
  "gAMA",
  "iCCP",
  "sBIT",
  "sRGB",
  "cICP",
  "bKGD",
  "pHYs",
]);
const PNG_ANIMATION = new Set(["acTL", "fcTL", "fdAT"]);
const WEBP_KEEP = new Set(["VP8X", "VP8 ", "VP8L", "ALPH", "ICCP"]);
const WEBP_ANIMATION = new Set(["ANIM", "ANMF"]);
// VP8X flag bits: EXIF 0x08, XMP 0x04, animation 0x02.
const VP8X_METADATA_FLAGS = 0x0c;
const VP8X_ANIMATION_FLAG = 0x02;

function ascii(bytes: Uint8Array, at: number, length: number): string {
  return String.fromCharCode(...bytes.subarray(at, at + length));
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** The container the magic bytes name, or null for anything else. */
export function sniff(bytes: Uint8Array): ImageKind | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpeg";
  if (bytes.length >= 8 && PNG_SIGNATURE.every((b, i) => bytes[i] === b)) return "png";
  if (bytes.length >= 12 && ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP") return "webp";
  return null;
}

/** Strips every metadata block and reads the dimensions. Throws MediaError on anything else. */
export function stripMetadata(input: Uint8Array): StrippedImage {
  const kind = sniff(input);
  if (!kind) throw new MediaError("bad_type");
  const result = kind === "jpeg" ? stripJpeg(input) : kind === "png" ? stripPng(input) : stripWebp(input);
  if (!(result.width > 0 && result.height > 0)) throw new MediaError("corrupt");
  return { kind, ...KINDS[kind], ...result };
}

type Stripped = { width: number; height: number; bytes: Uint8Array };

// ---------------------------------------------------------------------------
// JPEG: markers FFxx; every segment but SOI, EOI, RSTn and TEM carries a two-byte length.
// Kept: frame and scan structure (C0-CF, DB-DF, DA). Dropped: APP1-APP15, COM and the reserved
// JPGn range (F0-FD). APP0 is kept only as a bare JFIF header with any embedded thumbnail cut
// away; anything else in APP0 (a JFXX thumbnail) goes. Entropy-coded data after SOS runs to the
// next marker that is not a stuffed FF00 or a restart marker, and anything after EOI goes too:
// that is where some phones append a second picture.
// ---------------------------------------------------------------------------
function jpegKeeps(marker: number): boolean {
  return (marker >= 0xc0 && marker <= 0xcf) || (marker >= 0xda && marker <= 0xdf);
}

function stripJpeg(b: Uint8Array): Stripped {
  const parts: Uint8Array[] = [b.subarray(0, 2)];
  let width = 0, height = 0;
  let i = 2;
  while (true) {
    if (i + 1 >= b.length || b[i] !== 0xff) throw new MediaError("corrupt");
    // Fill bytes: any number of FF before a marker.
    while (i + 1 < b.length && b[i + 1] === 0xff) i++;
    const marker = b[i + 1];
    if (marker === 0xd9) {
      parts.push(b.subarray(i, i + 2));
      break;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      parts.push(b.subarray(i, i + 2));
      i += 2;
      continue;
    }
    if (i + 4 > b.length) throw new MediaError("corrupt");
    const length = (b[i + 2] << 8) | b[i + 3];
    const end = i + 2 + length;
    if (length < 2 || end > b.length) throw new MediaError("corrupt");

    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      if (length < 8) throw new MediaError("corrupt");
      height = (b[i + 5] << 8) | b[i + 6];
      width = (b[i + 7] << 8) | b[i + 8];
    }

    if (marker === 0xe0) {
      if (length >= 16 && ascii(b, i + 4, 5) === "JFIF\0") {
        // The JFIF header is 14 bytes of payload; Xthumbnail × Ythumbnail × 3 bytes follow it.
        const header = b.slice(i, i + 2 + 16);
        header[2] = 0;
        header[3] = 16;
        header[16] = 0;
        header[17] = 0;
        parts.push(header);
      }
    } else if (jpegKeeps(marker)) {
      parts.push(b.subarray(i, end));
    }
    i = end;

    if (marker === 0xda) {
      let j = i;
      while (j + 1 < b.length) {
        const next = b[j + 1];
        if (b[j] === 0xff && next !== 0x00 && next !== 0xff && !(next >= 0xd0 && next <= 0xd7)) break;
        j++;
      }
      if (j + 1 >= b.length) throw new MediaError("corrupt");
      parts.push(b.subarray(i, j));
      i = j;
    }
  }
  return { width, height, bytes: concat(parts) };
}

// ---------------------------------------------------------------------------
// PNG: signature, then length (BE) · type · data · CRC chunks until IEND. An unknown critical
// chunk (upper-case first letter) cannot be dropped without breaking the image, so the file is
// refused; every ancillary chunk not on the keep list is dropped. Anything after IEND goes.
// ---------------------------------------------------------------------------
function stripPng(b: Uint8Array): Stripped {
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const parts: Uint8Array[] = [b.subarray(0, 8)];
  let width = 0, height = 0;
  let i = 8;
  while (true) {
    if (i + 12 > b.length) throw new MediaError("corrupt");
    const length = view.getUint32(i);
    const type = ascii(b, i + 4, 4);
    const end = i + 12 + length;
    if (end > b.length || !/^[A-Za-z]{4}$/.test(type)) throw new MediaError("corrupt");
    if (i === 8) {
      if (type !== "IHDR" || length !== 13) throw new MediaError("corrupt");
      width = view.getUint32(i + 8);
      height = view.getUint32(i + 12);
    }
    if (PNG_ANIMATION.has(type)) throw new MediaError("animated");
    if (PNG_KEEP.has(type)) parts.push(b.subarray(i, end));
    else if (type[0] === type[0].toUpperCase()) throw new MediaError("corrupt");
    i = end;
    if (type === "IEND") break;
  }
  return { width, height, bytes: concat(parts) };
}

// ---------------------------------------------------------------------------
// WebP: RIFF · size (LE) · WEBP, then fourcc · size (LE) · data chunks padded to even length.
// Only the image, alpha and colour-profile chunks are kept, the VP8X flags announcing EXIF and
// XMP are cleared, and the RIFF size is rewritten. Bytes past the RIFF size go.
// ---------------------------------------------------------------------------
function stripWebp(b: Uint8Array): Stripped {
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const riffEnd = 8 + view.getUint32(4, true);
  if (riffEnd > b.length || riffEnd < 12) throw new MediaError("corrupt");
  const chunks: Uint8Array[] = [];
  let width = 0, height = 0;
  let image = false;
  let i = 12;
  while (i < riffEnd) {
    if (i + 8 > riffEnd) throw new MediaError("corrupt");
    const type = ascii(b, i, 4);
    const size = view.getUint32(i + 4, true);
    const end = i + 8 + size + (size & 1);
    if (end > riffEnd) throw new MediaError("corrupt");
    const at = i + 8;
    if (WEBP_ANIMATION.has(type)) throw new MediaError("animated");
    if (type === "VP8X") {
      if (size < 10) throw new MediaError("corrupt");
      if (b[at] & VP8X_ANIMATION_FLAG) throw new MediaError("animated");
      const chunk = b.slice(i, end);
      chunk[8] &= ~VP8X_METADATA_FLAGS;
      chunks.push(chunk);
      width = 1 + (b[at + 4] | (b[at + 5] << 8) | (b[at + 6] << 16));
      height = 1 + (b[at + 7] | (b[at + 8] << 8) | (b[at + 9] << 16));
    } else if (WEBP_KEEP.has(type)) {
      chunks.push(b.subarray(i, end));
      if (type === "VP8 ") {
        // Lossy key frame: a 3-byte frame tag, start code 9D 01 2A, then 14-bit width and height.
        if (size < 10 || b[at + 3] !== 0x9d || b[at + 4] !== 0x01 || b[at + 5] !== 0x2a) {
          throw new MediaError("corrupt");
        }
        if (!width) {
          width = view.getUint16(at + 6, true) & 0x3fff;
          height = view.getUint16(at + 8, true) & 0x3fff;
        }
        image = true;
      } else if (type === "VP8L") {
        // Lossless: signature 2F, then width-1 and height-1 as 14-bit little-endian fields.
        if (size < 5 || b[at] !== 0x2f) throw new MediaError("corrupt");
        if (!width) {
          const bits = view.getUint32(at + 1, true);
          width = (bits & 0x3fff) + 1;
          height = ((bits >>> 14) & 0x3fff) + 1;
        }
        image = true;
      }
    }
    i = end;
  }
  if (!image) throw new MediaError("corrupt");
  const body = concat(chunks);
  const header = new Uint8Array(12);
  header.set(b.subarray(0, 12));
  new DataView(header.buffer).setUint32(4, 4 + body.length, true);
  return { width, height, bytes: concat([header, body]) };
}

/**
 * The blocks still present that are not on the keep lists, by name. Empty for anything this
 * module produced; the worker checks it once more before a file is written.
 */
export function metadataBlocks(input: Uint8Array): string[] {
  const kind = sniff(input);
  const found: string[] = [];
  if (kind === "jpeg") {
    let i = 2;
    while (i + 3 < input.length && input[i] === 0xff) {
      const m = input[i + 1];
      if (m === 0xda || m === 0xd9) break;
      if (m === 0xe0 ? ascii(input, i + 4, 5) !== "JFIF\0" || input[i + 3] !== 16 : !jpegKeeps(m)) {
        found.push(`jpeg:${m.toString(16)}`);
      }
      i += 2 + ((input[i + 2] << 8) | input[i + 3]);
    }
  } else if (kind === "png") {
    const view = new DataView(input.buffer, input.byteOffset, input.byteLength);
    for (let i = 8; i + 8 <= input.length;) {
      const type = ascii(input, i + 4, 4);
      if (!PNG_KEEP.has(type)) found.push(`png:${type}`);
      i += 12 + view.getUint32(i);
    }
  } else if (kind === "webp") {
    const view = new DataView(input.buffer, input.byteOffset, input.byteLength);
    for (let i = 12; i + 8 <= input.length;) {
      const type = ascii(input, i, 4);
      const size = view.getUint32(i + 4, true);
      if (!WEBP_KEEP.has(type)) found.push(`webp:${type.trim()}`);
      if (type === "VP8X" && (input[i + 8] & VP8X_METADATA_FLAGS) !== 0) found.push("webp:VP8X-flags");
      i += 8 + size + (size & 1);
    }
  }
  return found;
}
