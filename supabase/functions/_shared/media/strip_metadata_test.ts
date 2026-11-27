import { assert, assertEquals, assertThrows } from "@std/assert";
import images from "./testdata/images.json" with { type: "json" };
import { MediaError, metadataBlocks, sniff, stripMetadata } from "./strip_metadata.ts";

function image(name: keyof typeof images): Uint8Array {
  return Uint8Array.from(atob(images[name]), (c) => c.charCodeAt(0));
}

function contains(haystack: Uint8Array, needle: string): boolean {
  const n = new TextEncoder().encode(needle);
  outer: for (let i = 0; i + n.length <= haystack.length; i++) {
    for (let j = 0; j < n.length; j++) if (haystack[i + j] !== n[j]) continue outer;
    return true;
  }
  return false;
}

/** Every string a phone's metadata put in the fixtures; none may survive. */
const LEAKS = [
  "Exif",
  "GPS",
  "http://ns.adobe.com",
  "xpacket",
  "PhoneMaker",
  "PhoneModel",
  "2026:11:20",
  "Admiralty",
  "Bode Thomas",
  "6.5244",
  "tEXt",
  "zTXt",
  "iTXt",
  "eXIf",
  "tIME",
  "EXIF",
  "XMP ",
];

function assertNoLeaks(bytes: Uint8Array) {
  for (const leak of LEAKS) assert(!contains(bytes, leak), `"${leak}" survived`);
}

Deno.test("the fixtures really do carry metadata", () => {
  assertEquals(metadataBlocks(image("gps_exif.jpg")), ["jpeg:e1", "jpeg:e1", "jpeg:fe"]);
  assertEquals(metadataBlocks(image("text_chunks.png")), [
    "png:tEXt",
    "png:iTXt",
    "png:zTXt",
    "png:eXIf",
    "png:tIME",
  ]);
  assertEquals(metadataBlocks(image("xmp_exif.webp")), ["webp:VP8X-flags", "webp:EXIF", "webp:XMP"]);
  assert(contains(image("gps_exif.jpg"), "GPS") || contains(image("gps_exif.jpg"), "Exif"));
});

Deno.test("JPEG: EXIF with GPS, XMP and the comment are gone; the scan is untouched", () => {
  const input = image("gps_exif.jpg");
  const out = stripMetadata(input);
  assertEquals([out.kind, out.mime, out.extension, out.width, out.height], [
    "jpeg",
    "image/jpeg",
    "jpg",
    400,
    320,
  ]);
  assertEquals(metadataBlocks(out.bytes), []);
  assertNoLeaks(out.bytes);
  // The entropy-coded scan, SOS to EOI, is byte-for-byte what the camera wrote.
  const sos = (b: Uint8Array) => b.findIndex((v, i) => v === 0xff && b[i + 1] === 0xda);
  assertEquals(out.bytes.subarray(sos(out.bytes)), input.subarray(sos(input)));
  // Still a JPEG with its JFIF header first.
  assertEquals([...out.bytes.subarray(0, 4)], [0xff, 0xd8, 0xff, 0xe0]);
  assertEquals(stripMetadata(out.bytes).bytes, out.bytes, "stripping is idempotent");
});

Deno.test("JPEG: an embedded JFIF thumbnail and bytes after EOI are dropped", () => {
  const input = image("gps_exif.jpg");
  const app0 = input.subarray(2, 2 + 18);
  // Rebuild APP0 with a 1×1 thumbnail (3 bytes of RGB) and append a second picture after EOI.
  const withThumb = new Uint8Array([...app0.subarray(0, 16), 1, 1, 0xaa, 0xbb, 0xcc]);
  withThumb[3] = 16 + 3;
  const trailer = new TextEncoder().encode("SECOND-PICTURE");
  const crafted = new Uint8Array([...input.subarray(0, 2), ...withThumb, ...input.subarray(20), ...trailer]);
  const out = stripMetadata(crafted);
  assert(!contains(out.bytes, "SECOND-PICTURE"));
  // SOI (2) + marker and length (4) + "JFIF\0" (5) + version, units and densities (7).
  assertEquals([out.bytes[18], out.bytes[19]], [0, 0], "Xthumbnail and Ythumbnail are zero");
  assertEquals(out.bytes, stripMetadata(input).bytes, "only the thumbnail and the trailer differed, and both are gone");
  assertEquals((out.bytes[4] << 8) | out.bytes[5], 16);
  assertEquals([...out.bytes.subarray(-2)], [0xff, 0xd9]);
});

Deno.test("PNG: tEXt, zTXt, iTXt, eXIf and tIME are gone; IHDR and IDAT are untouched", () => {
  const input = image("text_chunks.png");
  const out = stripMetadata(input);
  assertEquals([out.kind, out.mime, out.extension, out.width, out.height], [
    "png",
    "image/png",
    "png",
    240,
    200,
  ]);
  assertEquals(metadataBlocks(out.bytes), []);
  assertNoLeaks(out.bytes);
  const chunk = (b: Uint8Array, type: string) => {
    const at = b.findIndex((_, i) => String.fromCharCode(...b.subarray(i + 4, i + 8)) === type);
    const length = new DataView(b.buffer, b.byteOffset).getUint32(at);
    return b.subarray(at, at + 12 + length);
  };
  assertEquals(chunk(out.bytes, "IHDR"), chunk(input, "IHDR"));
  assertEquals(chunk(out.bytes, "IDAT"), chunk(input, "IDAT"), "the pixels, CRC included, as written");
  assertEquals(String.fromCharCode(...out.bytes.subarray(-8, -4)), "IEND");
});

Deno.test("WebP: EXIF and XMP chunks are gone, VP8X stops announcing them, the RIFF size is right", () => {
  const input = image("xmp_exif.webp");
  const out = stripMetadata(input);
  assertEquals([out.kind, out.mime, out.extension, out.width, out.height], [
    "webp",
    "image/webp",
    "webp",
    360,
    400,
  ]);
  assertEquals(metadataBlocks(out.bytes), []);
  assertNoLeaks(out.bytes);
  const view = new DataView(out.bytes.buffer, out.bytes.byteOffset);
  assertEquals(view.getUint32(4, true), out.bytes.length - 8);
  assertEquals(out.bytes[20] & 0x0c, 0, "the EXIF and XMP flags are cleared");
  const vp8 = (b: Uint8Array) =>
    b.subarray(b.findIndex((_, i) => String.fromCharCode(...b.subarray(i, i + 4)) === "VP8 "));
  assertEquals(vp8(out.bytes), vp8(input).subarray(0, vp8(out.bytes).length), "the frame is untouched");
});

Deno.test("WebP: a lossless image with no metadata comes out as it went in", () => {
  const input = image("plain_lossless.webp");
  const out = stripMetadata(input);
  assertEquals([out.width, out.height], [320, 400]);
  assertEquals(out.bytes, input);
});

Deno.test("anything that is not one of the three containers is refused", () => {
  const cases: [Uint8Array, string][] = [
    [new TextEncoder().encode("<svg xmlns='http://www.w3.org/2000/svg'/>"), "bad_type"],
    [new TextEncoder().encode("GIF89a........"), "bad_type"],
    [new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d]), "bad_type"],
    [new Uint8Array([]), "bad_type"],
  ];
  for (const [bytes, reason] of cases) {
    const error = assertThrows(() => stripMetadata(bytes), MediaError);
    assertEquals(error.reason, reason);
  }
  assertEquals(sniff(image("gps_exif.jpg")), "jpeg");
});

Deno.test("a truncated or malformed container is refused, never passed through", () => {
  for (const name of ["gps_exif.jpg", "text_chunks.png", "xmp_exif.webp"] as const) {
    const input = image(name);
    const error = assertThrows(() => stripMetadata(input.subarray(0, Math.floor(input.length / 2))), MediaError);
    assertEquals(error.reason, "corrupt", name);
  }
  // A JPEG segment whose length runs past the end of the file.
  const jpeg = image("gps_exif.jpg").slice();
  jpeg[4] = 0xff;
  jpeg[5] = 0xff;
  assertEquals(assertThrows(() => stripMetadata(jpeg), MediaError).reason, "corrupt");
  // A PNG with an unknown critical chunk cannot be repaired by dropping it.
  const png = image("text_chunks.png").slice();
  const at = png.findIndex((_, i) => String.fromCharCode(...png.subarray(i, i + 4)) === "tEXt");
  png.set(new TextEncoder().encode("ZZZZ"), at);
  assertEquals(assertThrows(() => stripMetadata(png), MediaError).reason, "corrupt");
});

Deno.test("animation is refused: a moderator approves the frame they see", () => {
  const webp = image("xmp_exif.webp").slice();
  webp[20] |= 0x02;
  assertEquals(assertThrows(() => stripMetadata(webp), MediaError).reason, "animated");
  const png = image("text_chunks.png").slice();
  const at = png.findIndex((_, i) => String.fromCharCode(...png.subarray(i, i + 4)) === "tIME");
  png.set(new TextEncoder().encode("acTL"), at);
  assertEquals(assertThrows(() => stripMetadata(png), MediaError).reason, "animated");
});
