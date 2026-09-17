// Apple App Attest — server-side verification of attestations and assertions.
// Steps follow developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
// and the sample in /attestation-object-validation-guide (both checked 2026-09-17) [V].
// The assertion signature is ECDSA with SHA-256 over `nonce`, as in the MIT-licensed
// github.com/takimoto3/app-attest (`ecdsa.VerifyASN1(key, sha256(nonce), sig)`) [S], and confirmed
// against a real iOS 14.4 assertion in the tests.
//
// Both functions take `clientDataHash`, the value the app passed to attestKey / generateAssertion.
// Protocol between app and server (Suskii): the app obtains a nonce from request_integrity_nonce
// and passes clientDataHash = SHA-256(UTF-8 bytes of the nonce). Because the server rebuilds that
// hash from the nonce it issued, Apple's "embedded challenge matches" step holds by construction.

import { asBytes, asMap, decodeCbor, decodeCborItem } from "./cbor.ts";
import {
  bytesEqual,
  type Certificate,
  children,
  content,
  ecdsaDerToRaw,
  isCa,
  parseCertificate,
  pemToDer,
  readTlv,
  TAG,
  verifySignedBy,
} from "./der.ts";

/** Apple App Attestation Root CA, www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem.
 *  SHA-256 fingerprint 1CB9823BA28BA6AD2D33A006941DE2AE4F513EF1D4E831B9F7E0FA7B6242C932 (checked 2026-09-17). */
export const APPLE_APP_ATTEST_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";
const AAGUID_DEVELOPMENT = new TextEncoder().encode("appattestdevelop");
const AAGUID_PRODUCTION = new Uint8Array([...new TextEncoder().encode("appattest"), 0, 0, 0, 0, 0, 0, 0]);

export type AppAttestEnvironment = "development" | "production";

export interface AppAttestPolicy {
  /** App ID: team ID prefix, a period, and the bundle identifier. */
  appId: string;
  environment: AppAttestEnvironment;
  /**
   * Launch validation categories accepted when the authenticator data carries
   * `apple_validation_category_01` (1 OS, 2 TestFlight, 3 development signing, 4 App Store).
   * Attestations from OS versions that do not include the extension are accepted without it.
   */
  allowedValidationCategories: number[];
}

export interface AppleExtensions {
  validationCategory?: number;
  bundleVersion?: string;
}

export type AttestationOutcome =
  | { ok: true; publicKey: Uint8Array; receipt: Uint8Array; extensions: AppleExtensions }
  | { ok: false; reason: string };

export type AssertionOutcome =
  | { ok: true; counter: number; extensions: AppleExtensions }
  | { ok: false; reason: string };

export async function sha256(...parts: Uint8Array[]): Promise<Uint8Array<ArrayBuffer>> {
  const joined = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    joined.set(p, offset);
    offset += p.length;
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", joined));
}

function withinValidity(cert: Certificate, now: Date): boolean {
  return cert.notBefore.getTime() <= now.getTime() && now.getTime() <= cert.notAfter.getTime();
}

interface AuthenticatorData {
  rpIdHash: Uint8Array;
  counter: number;
  aaguid?: Uint8Array;
  credentialId?: Uint8Array;
  coseKey?: Map<unknown, unknown>;
  extensions: AppleExtensions;
}

function parseAuthenticatorData(data: Uint8Array, attested: boolean): AuthenticatorData {
  if (data.length < 37) throw new Error("authdata_truncated");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const result: AuthenticatorData = {
    rpIdHash: data.subarray(0, 32),
    counter: view.getUint32(33),
    extensions: {},
  };
  let offset = 37;
  if (attested) {
    if (data.length < offset + 18) throw new Error("authdata_truncated");
    result.aaguid = data.subarray(offset, offset + 16);
    const idLength = view.getUint16(offset + 16);
    offset += 18;
    if (data.length < offset + idLength) throw new Error("authdata_truncated");
    result.credentialId = data.subarray(offset, offset + idLength);
    offset += idLength;
    const cose = decodeCborItem(data, offset);
    result.coseKey = asMap(cose.value, "cose_key");
    offset = cose.end;
  }
  if (offset < data.length) {
    const ext = decodeCborItem(data, offset);
    if (ext.end !== data.length) throw new Error("authdata_trailing_bytes");
    result.extensions = readAppleExtensions(asMap(ext.value, "extensions"));
  }
  return result;
}

function readAppleExtensions(map: Map<unknown, unknown>): AppleExtensions {
  const out: AppleExtensions = {};
  const category = map.get("apple_validation_category_01") ?? map.get("validationCategory");
  if (typeof category === "number") {
    out.validationCategory = category;
  } else if (category instanceof Uint8Array && category.length === 4) {
    // Apple documents a UInt32; the guide's sample encodes the value 1 as bytes 01 00 00 00,
    // so it is read little-endian [V: sample value, A: byte order beyond that sample].
    out.validationCategory = new DataView(category.buffer, category.byteOffset, 4).getUint32(0, true);
  } else if (category !== undefined) {
    throw new Error("extensions_bad_validation_category");
  }
  const version = map.get("apple_bundle_version_01") ?? map.get("bundleVersion");
  if (typeof version === "string") out.bundleVersion = version;
  else if (version !== undefined) throw new Error("extensions_bad_bundle_version");
  return out;
}

function categoryAllowed(ext: AppleExtensions, policy: AppAttestPolicy): boolean {
  return ext.validationCategory === undefined || policy.allowedValidationCategories.includes(ext.validationCategory);
}

/** The single OCTET STRING inside the nonce extension: SEQUENCE { [1] { OCTET STRING } }. */
function extractNonce(value: Uint8Array): Uint8Array {
  const seq = readTlv(value, 0);
  if (seq.tag !== TAG.SEQUENCE || seq.end !== value.length) throw new Error("nonce_extension_malformed");
  const tagged = children(value, seq);
  if (tagged.length !== 1 || tagged[0].tag !== 0xa1) throw new Error("nonce_extension_malformed");
  const inner = children(value, tagged[0]);
  if (inner.length !== 1 || inner[0].tag !== TAG.OCTET_STRING) throw new Error("nonce_extension_malformed");
  return content(value, inner[0]);
}

/**
 * Verifies an attestation object for `keyId` (the raw 32-byte key identifier the app sends,
 * base64-decoded) against the clientDataHash the app attested.
 */
export async function verifyAttestation(
  attestationObject: Uint8Array,
  keyId: Uint8Array,
  clientDataHash: Uint8Array,
  policy: AppAttestPolicy,
  now: Date,
  rootPem: string = APPLE_APP_ATTEST_ROOT_PEM,
): Promise<AttestationOutcome> {
  let leaf: Certificate, intermediate: Certificate, authDataBytes: Uint8Array, receipt: Uint8Array;
  try {
    const decoded = asMap(decodeCbor(attestationObject), "attestation");
    if (decoded.get("fmt") !== "apple-appattest") return { ok: false, reason: "attestation_format_invalid" };
    const statement = asMap(decoded.get("attStmt"), "attStmt");
    const x5c = statement.get("x5c");
    authDataBytes = asBytes(decoded.get("authData"), "authData");
    receipt = asBytes(statement.get("receipt"), "receipt");
    if (!Array.isArray(x5c) || x5c.length !== 2) return { ok: false, reason: "certificate_chain_invalid" };
    leaf = parseCertificate(asBytes(x5c[0], "credCert"));
    intermediate = parseCertificate(asBytes(x5c[1], "caCert"));
  } catch {
    return { ok: false, reason: "attestation_malformed" };
  }

  // Step 1: credCert ← intermediate ← pinned Apple App Attestation Root CA, all valid now.
  const root = parseCertificate(pemToDer(rootPem));
  const chainOk = isCa(intermediate) && isCa(root) &&
    bytesEqual(leaf.issuer, intermediate.subject) && bytesEqual(intermediate.issuer, root.subject) &&
    withinValidity(leaf, now) && withinValidity(intermediate, now) && withinValidity(root, now) &&
    await verifySignedBy(leaf, intermediate).catch(() => false) &&
    await verifySignedBy(intermediate, root).catch(() => false);
  if (!chainOk) return { ok: false, reason: "certificate_chain_invalid" };

  let authData: AuthenticatorData;
  try {
    authData = parseAuthenticatorData(authDataBytes, true);
  } catch {
    return { ok: false, reason: "attestation_malformed" };
  }

  // Steps 2–4: nonce = SHA-256(authData || clientDataHash) must equal the credCert extension.
  const nonce = await sha256(authDataBytes, clientDataHash);
  const nonceExtension = leaf.extensions.get(NONCE_EXTENSION_OID);
  let certNonce: Uint8Array;
  try {
    if (!nonceExtension) return { ok: false, reason: "nonce_mismatch" };
    certNonce = extractNonce(nonceExtension);
  } catch {
    return { ok: false, reason: "nonce_mismatch" };
  }
  if (!bytesEqual(certNonce, nonce)) return { ok: false, reason: "nonce_mismatch" };

  // Step 5: SHA-256 of the credCert public key (X9.62 uncompressed point) is the key identifier.
  let publicKey: Uint8Array;
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      leaf.spki as Uint8Array<ArrayBuffer>,
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["verify"],
    );
    publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", key));
  } catch {
    return { ok: false, reason: "certificate_chain_invalid" };
  }
  if (!bytesEqual(await sha256(publicKey), keyId)) return { ok: false, reason: "key_id_mismatch" };

  // Steps 6–9.
  if (!bytesEqual(authData.rpIdHash, await sha256(new TextEncoder().encode(policy.appId)))) {
    return { ok: false, reason: "app_id_mismatch" };
  }
  if (authData.counter !== 0) return { ok: false, reason: "counter_invalid" };
  const expectedAaguid = policy.environment === "production" ? AAGUID_PRODUCTION : AAGUID_DEVELOPMENT;
  if (!authData.aaguid || !bytesEqual(authData.aaguid, expectedAaguid)) {
    return { ok: false, reason: "environment_mismatch" };
  }
  if (!authData.credentialId || !bytesEqual(authData.credentialId, keyId)) {
    return { ok: false, reason: "key_id_mismatch" };
  }

  // Not an Apple step, but cheap: the COSE key in authData must be the certified key.
  const x = authData.coseKey?.get(-2);
  const y = authData.coseKey?.get(-3);
  if (
    !(x instanceof Uint8Array) || !(y instanceof Uint8Array) ||
    !bytesEqual(new Uint8Array([4, ...x, ...y]), publicKey)
  ) {
    return { ok: false, reason: "public_key_mismatch" };
  }

  // Steps 10–11.
  if (!categoryAllowed(authData.extensions, policy)) return { ok: false, reason: "validation_category_not_allowed" };

  return { ok: true, publicKey, receipt, extensions: authData.extensions };
}

/**
 * Verifies an assertion made with a previously attested key. `publicKey` is the stored
 * 65-byte uncompressed point; `previousCounter` is the stored counter (0 before the first assertion).
 */
export async function verifyAssertion(
  assertionObject: Uint8Array,
  clientDataHash: Uint8Array,
  publicKey: Uint8Array,
  previousCounter: number,
  policy: AppAttestPolicy,
): Promise<AssertionOutcome> {
  let signature: Uint8Array, authDataBytes: Uint8Array, authData: AuthenticatorData;
  try {
    const decoded = asMap(decodeCbor(assertionObject), "assertion");
    signature = asBytes(decoded.get("signature"), "signature");
    authDataBytes = asBytes(decoded.get("authenticatorData"), "authenticatorData");
    authData = parseAuthenticatorData(authDataBytes, false);
  } catch {
    return { ok: false, reason: "assertion_malformed" };
  }

  // Steps 1–3.
  const nonce = await sha256(authDataBytes, clientDataHash);
  let valid = false;
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      publicKey as Uint8Array<ArrayBuffer>,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      ecdsaDerToRaw(signature, 32) as Uint8Array<ArrayBuffer>,
      nonce as Uint8Array<ArrayBuffer>,
    );
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, reason: "signature_invalid" };

  // Steps 4–5 (step 6 holds by construction; see the header comment).
  if (!bytesEqual(authData.rpIdHash, await sha256(new TextEncoder().encode(policy.appId)))) {
    return { ok: false, reason: "app_id_mismatch" };
  }
  if (authData.counter <= previousCounter) return { ok: false, reason: "counter_not_increasing" };

  // Steps 7–8.
  if (!categoryAllowed(authData.extensions, policy)) return { ok: false, reason: "validation_category_not_allowed" };

  return { ok: true, counter: authData.counter, extensions: authData.extensions };
}
