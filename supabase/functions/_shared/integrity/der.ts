// Minimal DER reader and X.509 certificate parser — only what App Attest verification needs
// (RFC 5280 certificate structure; ITU-T X.690 DER). Definite lengths only; anything
// unexpected throws, and callers treat a throw as a failed verification.

export interface Tlv {
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset of the first content byte. */
  contentStart: number;
  /** Offset just past the last content byte. */
  end: number;
}

export const TAG = {
  BOOLEAN: 0x01,
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  OID: 0x06,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
  SEQUENCE: 0x30,
} as const;

export function readTlv(bytes: Uint8Array, offset: number, limit = bytes.length): Tlv {
  if (offset + 2 > limit) throw new Error("der_truncated");
  const tag = bytes[offset];
  if ((tag & 0x1f) === 0x1f) throw new Error("der_high_tag_unsupported");
  let length = bytes[offset + 1];
  let header = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4) throw new Error("der_bad_length");
    if (offset + 2 + count > limit) throw new Error("der_truncated");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[offset + 2 + i];
    header += count;
  }
  const contentStart = offset + header;
  const end = contentStart + length;
  if (end > limit) throw new Error("der_truncated");
  return { tag, start: offset, contentStart, end };
}

export function children(bytes: Uint8Array, parent: Tlv): Tlv[] {
  const out: Tlv[] = [];
  let offset = parent.contentStart;
  while (offset < parent.end) {
    const child = readTlv(bytes, offset, parent.end);
    out.push(child);
    offset = child.end;
  }
  return out;
}

export function content(bytes: Uint8Array, tlv: Tlv): Uint8Array {
  return bytes.subarray(tlv.contentStart, tlv.end);
}

export function raw(bytes: Uint8Array, tlv: Tlv): Uint8Array {
  return bytes.subarray(tlv.start, tlv.end);
}

function expect(tlv: Tlv, tag: number): Tlv {
  if (tlv.tag !== tag) throw new Error(`der_unexpected_tag_${tlv.tag.toString(16)}`);
  return tlv;
}

export function decodeOid(value: Uint8Array): string {
  if (value.length === 0) throw new Error("der_bad_oid");
  const parts: number[] = [Math.floor(value[0] / 40), value[0] % 40];
  let acc = 0;
  for (let i = 1; i < value.length; i++) {
    acc = acc * 128 + (value[i] & 0x7f);
    if (!(value[i] & 0x80)) {
      parts.push(acc);
      acc = 0;
    }
  }
  return parts.join(".");
}

function decodeTime(bytes: Uint8Array, tlv: Tlv): Date {
  const text = new TextDecoder().decode(content(bytes, tlv));
  let m: RegExpMatchArray | null;
  if (tlv.tag === TAG.UTC_TIME && (m = text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    // RFC 5280 §4.1.2.5.1: YY >= 50 is 19YY.
    const yy = Number(m[1]);
    return new Date(Date.UTC(yy >= 50 ? 1900 + yy : 2000 + yy, +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
  }
  if (tlv.tag === TAG.GENERALIZED_TIME && (m = text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
  }
  throw new Error("der_bad_time");
}

export interface Certificate {
  der: Uint8Array;
  tbs: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: Date;
  notAfter: Date;
  /** DER SubjectPublicKeyInfo, importable with WebCrypto "spki". */
  spki: Uint8Array;
  /** OID of the EC named curve in the SubjectPublicKeyInfo, if any. */
  curveOid?: string;
  /** Extension OID → extnValue contents (the bytes inside the OCTET STRING). */
  extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const outer = expect(readTlv(der, 0), TAG.SEQUENCE);
  if (outer.end !== der.length) throw new Error("der_trailing_bytes");
  const [tbsTlv, algTlv, sigTlv] = children(der, outer);
  if (!tbsTlv || !algTlv || !sigTlv) throw new Error("x509_bad_structure");
  expect(tbsTlv, TAG.SEQUENCE);

  const signatureAlgorithm = decodeOid(content(der, expect(children(der, expect(algTlv, TAG.SEQUENCE))[0], TAG.OID)));
  const sigContent = content(der, expect(sigTlv, TAG.BIT_STRING));
  if (sigContent[0] !== 0) throw new Error("x509_bad_signature_bits");

  const fields = children(der, tbsTlv);
  let i = 0;
  if (fields[i]?.tag === 0xa0) i++; // [0] EXPLICIT version
  expect(fields[i++], TAG.INTEGER); // serialNumber
  expect(fields[i++], TAG.SEQUENCE); // signature algorithm (repeated)
  const issuer = raw(der, expect(fields[i++], TAG.SEQUENCE));
  const validity = children(der, expect(fields[i++], TAG.SEQUENCE));
  const subject = raw(der, expect(fields[i++], TAG.SEQUENCE));
  const spkiTlv = expect(fields[i++], TAG.SEQUENCE);
  if (validity.length !== 2) throw new Error("x509_bad_validity");

  let curveOid: string | undefined;
  const spkiAlg = children(der, expect(children(der, spkiTlv)[0], TAG.SEQUENCE));
  if (spkiAlg[1]?.tag === TAG.OID) curveOid = decodeOid(content(der, spkiAlg[1]));

  const extensions = new Map<string, Uint8Array>();
  for (; i < fields.length; i++) {
    if (fields[i].tag !== 0xa3) continue; // [3] EXPLICIT extensions
    const list = expect(children(der, fields[i])[0], TAG.SEQUENCE);
    for (const ext of children(der, list)) {
      const parts = children(der, expect(ext, TAG.SEQUENCE));
      const oid = decodeOid(content(der, expect(parts[0], TAG.OID)));
      const value = expect(parts[parts.length - 1], TAG.OCTET_STRING);
      if (extensions.has(oid)) throw new Error("x509_duplicate_extension");
      extensions.set(oid, content(der, value));
    }
  }

  return {
    der,
    tbs: raw(der, tbsTlv),
    signatureAlgorithm,
    signature: sigContent.subarray(1),
    issuer,
    subject,
    notBefore: decodeTime(der, validity[0]),
    notAfter: decodeTime(der, validity[1]),
    spki: raw(der, spkiTlv),
    curveOid,
    extensions,
  };
}

/** basicConstraints (2.5.29.19): true when cA is asserted. */
export function isCa(cert: Certificate): boolean {
  const value = cert.extensions.get("2.5.29.19");
  if (!value) return false;
  const seq = expect(readTlv(value, 0), TAG.SEQUENCE);
  const first = children(value, seq)[0];
  return first?.tag === TAG.BOOLEAN && content(value, first)[0] === 0xff;
}

export const CURVES: Record<string, { name: "P-256" | "P-384"; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};

const SIGNATURE_HASHES: Record<string, "SHA-256" | "SHA-384"> = {
  "1.2.840.10045.4.3.2": "SHA-256", // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": "SHA-384", // ecdsa-with-SHA384
};

/** Converts a DER ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) to WebCrypto's r || s. */
export function ecdsaDerToRaw(sig: Uint8Array, size: number): Uint8Array {
  const seq = expect(readTlv(sig, 0), TAG.SEQUENCE);
  if (seq.end !== sig.length) throw new Error("ecdsa_trailing_bytes");
  const ints = children(sig, seq);
  if (ints.length !== 2) throw new Error("ecdsa_bad_structure");
  const out = new Uint8Array(size * 2);
  ints.forEach((tlv, n) => {
    let value = content(sig, expect(tlv, TAG.INTEGER));
    while (value.length > 1 && value[0] === 0) value = value.subarray(1);
    if (value.length > size) throw new Error("ecdsa_integer_too_large");
    out.set(value, size * (n + 1) - value.length);
  });
  return out;
}

export async function importEcSpki(cert: Certificate): Promise<CryptoKey> {
  const curve = cert.curveOid ? CURVES[cert.curveOid] : undefined;
  if (!curve) throw new Error("x509_unsupported_key");
  return await crypto.subtle.importKey(
    "spki",
    cert.spki as Uint8Array<ArrayBuffer>,
    { name: "ECDSA", namedCurve: curve.name },
    true,
    ["verify"],
  );
}

/** True when `cert` carries a valid ECDSA signature by `issuer`'s key. */
export async function verifySignedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  const hash = SIGNATURE_HASHES[cert.signatureAlgorithm];
  const curve = issuer.curveOid ? CURVES[issuer.curveOid] : undefined;
  if (!hash || !curve) return false;
  const key = await importEcSpki(issuer);
  return await crypto.subtle.verify(
    { name: "ECDSA", hash },
    key,
    ecdsaDerToRaw(cert.signature, curve.size) as Uint8Array<ArrayBuffer>,
    cert.tbs as Uint8Array<ArrayBuffer>,
  );
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}
