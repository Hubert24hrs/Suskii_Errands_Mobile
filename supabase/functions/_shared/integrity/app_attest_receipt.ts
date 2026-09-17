// App Attest receipts: a PKCS #7 SignedData container (BER, indefinite lengths) signed by Apple,
// chaining to Apple Root CA - G3, with an ASN.1 payload of numbered fields.
// Steps and field numbers follow developer.apple.com/documentation/devicecheck/assessing-fraud-risk
// (checked 2026-09-17) [V]. Observed in real receipts [V: Apple's validation-guide sample and a
// real iOS 14.4 capture]: no signed attributes (the signature covers the payload octets), field 3
// holds the attested credential certificate, field 7 an environment string.

import {
  bytesEqual,
  type Certificate,
  CURVES,
  ecdsaDerToRaw,
  importEcSpki,
  isCa,
  parseCertificate,
  pemToDer,
  verifySignedBy,
} from "./der.ts";

/** Apple Root CA - G3, www.apple.com/certificateauthority/AppleRootCA-G3.cer (fetched 2026-09-17).
 *  SHA-256 fingerprint 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179. */
export const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

const OID_SIGNED_DATA = "1.2.840.113549.1.7.2";
const OID_MESSAGE_DIGEST = "1.2.840.113549.1.9.4";
const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const MAX_DEPTH = 32;

interface Node {
  tag: number;
  start: number;
  end: number;
  contentStart: number;
  contentEnd: number;
  children: Node[];
}

/** BER reader: definite and indefinite lengths; constructed values are parsed recursively. */
function parseBer(bytes: Uint8Array, offset: number, limit: number, depth = 0): Node {
  if (depth > MAX_DEPTH) throw new Error("ber_too_deep");
  if (offset + 2 > limit) throw new Error("ber_truncated");
  const tag = bytes[offset];
  if ((tag & 0x1f) === 0x1f) throw new Error("ber_high_tag_unsupported");
  const constructed = (tag & 0x20) !== 0;
  const first = bytes[offset + 1];
  let pos = offset + 2;

  if (first === 0x80) {
    if (!constructed) throw new Error("ber_indefinite_primitive");
    const children: Node[] = [];
    for (;;) {
      if (pos + 2 > limit) throw new Error("ber_truncated");
      if (bytes[pos] === 0 && bytes[pos + 1] === 0) {
        return { tag, start: offset, end: pos + 2, contentStart: offset + 2, contentEnd: pos, children };
      }
      const child = parseBer(bytes, pos, limit, depth + 1);
      children.push(child);
      pos = child.end;
    }
  }

  let length = first;
  if (first & 0x80) {
    const count = first & 0x7f;
    if (count > 4 || pos + count > limit) throw new Error("ber_bad_length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[pos + i];
    pos += count;
  }
  const end = pos + length;
  if (end > limit) throw new Error("ber_truncated");
  const children: Node[] = [];
  if (constructed) {
    let p = pos;
    while (p < end) {
      const child = parseBer(bytes, p, end, depth + 1);
      children.push(child);
      p = child.end;
    }
  }
  return { tag, start: offset, end, contentStart: pos, contentEnd: end, children };
}

function expectTag(node: Node | undefined, tag: number): Node {
  if (!node || node.tag !== tag) throw new Error(`ber_unexpected_tag_${node?.tag.toString(16)}`);
  return node;
}

function contentOf(bytes: Uint8Array, node: Node): Uint8Array {
  return bytes.subarray(node.contentStart, node.contentEnd);
}

/** OCTET STRING value, joining the chunks of a constructed (0x24) encoding. */
function octets(bytes: Uint8Array, node: Node): Uint8Array {
  if (node.tag === 0x04) return contentOf(bytes, node);
  if (node.tag !== 0x24) throw new Error("ber_expected_octet_string");
  const parts = node.children.map((c) => octets(bytes, c));
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function oid(bytes: Uint8Array, node: Node): string {
  const value = contentOf(bytes, expectTag(node, 0x06));
  const parts = [Math.floor(value[0] / 40), value[0] % 40];
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

function integer(bytes: Uint8Array, node: Node): number {
  const value = contentOf(bytes, expectTag(node, 0x02));
  if (value.length === 0 || value.length > 6 || value[0] & 0x80) throw new Error("ber_bad_integer");
  return value.reduce((n, b) => n * 256 + b, 0);
}

export interface AppAttestReceipt {
  appId: string;
  /** DER of the attested credential certificate (field 3). */
  attestedCertificate: Uint8Array;
  clientHash: Uint8Array;
  token: string;
  /** "ATTEST" for the receipt inside an attestation; "RECEIPT" for one refreshed from Apple. */
  type: string;
  environment?: string;
  creationTime: Date;
  /** Field 17, only on RECEIPT: approximate attested keys on the device over 30 days. */
  riskMetric?: number;
  notBefore?: Date;
  expirationTime?: Date;
}

interface Envelope {
  payload: Uint8Array;
  certificates: Certificate[];
  signer: Certificate;
  signature: Uint8Array;
  /** DER bytes the signature covers. */
  signedBytes: Uint8Array;
  messageDigest?: Uint8Array;
}

function parseEnvelope(bytes: Uint8Array): Envelope {
  const root = parseBer(bytes, 0, bytes.length);
  if (root.end !== bytes.length) throw new Error("ber_trailing_bytes");
  expectTag(root, 0x30);
  if (oid(bytes, root.children[0]) !== OID_SIGNED_DATA) throw new Error("receipt_not_signed_data");
  const signedData = expectTag(expectTag(root.children[1], 0xa0).children[0], 0x30);
  const [, , encap, ...rest] = signedData.children;

  const eContent = expectTag(expectTag(encap, 0x30).children[1], 0xa0).children[0];
  const payload = octets(bytes, eContent);

  const certSet = rest.find((n) => n.tag === 0xa0);
  const signerInfos = expectTag(rest[rest.length - 1], 0x31);
  if (!certSet || signerInfos.children.length !== 1) throw new Error("receipt_bad_signed_data");
  const certificates = certSet.children.map((c) => parseCertificate(bytes.slice(c.start, c.end)));

  const info = expectTag(signerInfos.children[0], 0x30).children;
  const sid = expectTag(info[1], 0x30); // issuerAndSerialNumber
  const issuer = bytes.subarray(sid.children[0].start, sid.children[0].end);
  const serial = contentOf(bytes, expectTag(sid.children[1], 0x02));
  const signer = certificates.find((c) => bytesEqual(c.issuer, issuer) && bytesEqual(serialOf(c), serial));
  if (!signer) throw new Error("receipt_signer_not_found");

  let i = 3;
  let signedBytes = payload;
  let messageDigest: Uint8Array | undefined;
  if (info[i]?.tag === 0xa0) {
    // Signed attributes: the signature covers their DER SET encoding (RFC 5652 §5.4).
    const attrs = info[i++];
    signedBytes = bytes.slice(attrs.start, attrs.end);
    signedBytes[0] = 0x31;
    for (const attr of attrs.children) {
      if (oid(bytes, attr.children[0]) === OID_MESSAGE_DIGEST) {
        messageDigest = contentOf(bytes, expectTag(attr.children[1].children[0], 0x04));
      }
    }
    if (!messageDigest) throw new Error("receipt_missing_message_digest");
  }
  if (oid(bytes, info[i++].children[0]) !== OID_ECDSA_SHA256) throw new Error("receipt_unsupported_signature");
  const signature = contentOf(bytes, expectTag(info[i], 0x04));
  return { payload, certificates, signer, signature, signedBytes, messageDigest };
}

function serialOf(cert: Certificate): Uint8Array {
  // tbs: [0] version, INTEGER serial, ...
  const tbs = parseBer(cert.tbs, 0, cert.tbs.length);
  const serial = tbs.children[0].tag === 0xa0 ? tbs.children[1] : tbs.children[0];
  return contentOf(cert.tbs, expectTag(serial, 0x02));
}

function parsePayload(payload: Uint8Array): AppAttestReceipt {
  const set = expectTag(parseBer(payload, 0, payload.length), 0x31);
  const fields = new Map<number, Uint8Array>();
  for (const entry of set.children) {
    const [type, , value] = expectTag(entry, 0x30).children;
    const n = integer(payload, type);
    if (fields.has(n)) throw new Error("receipt_duplicate_field");
    fields.set(n, octets(payload, value));
  }
  const text = (n: number) => {
    const v = fields.get(n);
    return v === undefined ? undefined : new TextDecoder("utf-8", { fatal: true }).decode(v);
  };
  const date = (n: number) => {
    const v = text(n);
    if (v === undefined || v === "") return undefined;
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) throw new Error(`receipt_bad_date_${n}`);
    return d;
  };
  const appId = text(2);
  const attestedCertificate = fields.get(3);
  const type = text(6);
  const creationTime = date(12);
  if (!appId || !attestedCertificate || !type || !creationTime) throw new Error("receipt_missing_fields");
  const metric = text(17);
  if (metric !== undefined && !/^\d{1,6}$/.test(metric)) throw new Error("receipt_bad_risk_metric");
  return {
    appId,
    attestedCertificate,
    clientHash: fields.get(4) ?? new Uint8Array(),
    token: text(5) ?? "",
    type,
    environment: text(7),
    creationTime,
    riskMetric: metric === undefined ? undefined : Number(metric),
    notBefore: date(19),
    expirationTime: date(21),
  };
}

export interface ReceiptExpectation {
  appId: string;
  /** Stored attested key: 65-byte uncompressed P-256 point. */
  publicKey: Uint8Array;
  now: Date;
  /** Apple: creation time no more than five minutes old. */
  maxAgeMs?: number;
}

export type ReceiptOutcome = { ok: true; receipt: AppAttestReceipt } | { ok: false; reason: string };

export async function verifyReceipt(
  bytes: Uint8Array,
  expected: ReceiptExpectation,
  rootPem: string = APPLE_ROOT_CA_G3_PEM,
): Promise<ReceiptOutcome> {
  let envelope: Envelope;
  let receipt: AppAttestReceipt;
  try {
    envelope = parseEnvelope(bytes);
    receipt = parsePayload(envelope.payload);
  } catch {
    return { ok: false, reason: "receipt_malformed" };
  }

  // Step 1: signature by the signer certificate.
  const signatureOk = await (async () => {
    const curve = envelope.signer.curveOid ? CURVES[envelope.signer.curveOid] : undefined;
    if (!curve) return false;
    if (envelope.messageDigest) {
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", envelope.payload as Uint8Array<ArrayBuffer>));
      if (!bytesEqual(digest, envelope.messageDigest)) return false;
    }
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      await importEcSpki(envelope.signer),
      ecdsaDerToRaw(envelope.signature, curve.size) as Uint8Array<ArrayBuffer>,
      envelope.signedBytes as Uint8Array<ArrayBuffer>,
    );
  })().catch(() => false);
  if (!signatureOk) return { ok: false, reason: "receipt_signature_invalid" };

  // Step 2: signer ← intermediate (from the container) ← pinned Apple Root CA - G3, all valid now.
  const root = parseCertificate(pemToDer(rootPem));
  const valid = (c: Certificate) => c.notBefore <= expected.now && expected.now <= c.notAfter;
  const intermediate = envelope.certificates.find((c) =>
    c !== envelope.signer && isCa(c) && bytesEqual(c.subject, envelope.signer.issuer) &&
    bytesEqual(c.issuer, root.subject)
  );
  const chainOk = !!intermediate && !isCa(envelope.signer) && isCa(root) &&
    valid(envelope.signer) && valid(intermediate) && valid(root) &&
    await verifySignedBy(envelope.signer, intermediate).catch(() => false) &&
    await verifySignedBy(intermediate, root).catch(() => false);
  if (!chainOk) return { ok: false, reason: "receipt_chain_invalid" };

  // Steps 4–6.
  if (receipt.appId !== expected.appId) return { ok: false, reason: "receipt_app_id_mismatch" };
  const age = expected.now.getTime() - receipt.creationTime.getTime();
  if (age > (expected.maxAgeMs ?? 5 * 60_000) || age < -60_000) return { ok: false, reason: "receipt_stale" };
  let attestedKey: Uint8Array;
  try {
    const cert = parseCertificate(receipt.attestedCertificate);
    attestedKey = new Uint8Array(await crypto.subtle.exportKey("raw", await importEcSpki(cert)));
  } catch {
    return { ok: false, reason: "receipt_public_key_mismatch" };
  }
  if (!bytesEqual(attestedKey, expected.publicKey)) return { ok: false, reason: "receipt_public_key_mismatch" };

  return { ok: true, receipt };
}
