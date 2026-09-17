// Minimal CBOR decoder (RFC 8949) for App Attest objects: unsigned and negative integers,
// byte and text strings, arrays, maps, tags (value kept, tag dropped), false/true/null.
// Indefinite lengths, floats and 64-bit integers beyond Number's safe range are refused.

export type CborValue =
  | number
  | Uint8Array
  | string
  | boolean
  | null
  | CborValue[]
  | Map<CborValue, CborValue>;

const MAX_DEPTH = 16;

export interface Decoded {
  value: CborValue;
  /** Offset just past the decoded item. */
  end: number;
}

export function decodeCbor(bytes: Uint8Array): CborValue {
  const { value, end } = decodeCborItem(bytes, 0);
  if (end !== bytes.length) throw new Error("cbor_trailing_bytes");
  return value;
}

export function decodeCborItem(bytes: Uint8Array, offset: number): Decoded {
  let pos = offset;

  const need = (n: number) => {
    if (pos + n > bytes.length) throw new Error("cbor_truncated");
  };

  const readArgument = (info: number): number => {
    if (info < 24) return info;
    const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
    if (size === 0) throw new Error("cbor_unsupported_length");
    need(size);
    let n = 0;
    for (let i = 0; i < size; i++) n = n * 256 + bytes[pos + i];
    pos += size;
    if (!Number.isSafeInteger(n)) throw new Error("cbor_integer_too_large");
    return n;
  };

  const item = (depth: number): CborValue => {
    if (depth > MAX_DEPTH) throw new Error("cbor_too_deep");
    need(1);
    const initial = bytes[pos++];
    const major = initial >> 5;
    const info = initial & 0x1f;

    switch (major) {
      case 0:
        return readArgument(info);
      case 1:
        return -1 - readArgument(info);
      case 2:
      case 3: {
        const length = readArgument(info);
        need(length);
        const slice = bytes.subarray(pos, pos + length);
        pos += length;
        return major === 2 ? slice : new TextDecoder("utf-8", { fatal: true }).decode(slice);
      }
      case 4: {
        const length = readArgument(info);
        const out: CborValue[] = [];
        for (let i = 0; i < length; i++) out.push(item(depth + 1));
        return out;
      }
      case 5: {
        const length = readArgument(info);
        const out = new Map<CborValue, CborValue>();
        for (let i = 0; i < length; i++) {
          const key = item(depth + 1);
          if (typeof key !== "string" && typeof key !== "number") throw new Error("cbor_unsupported_key");
          if (out.has(key)) throw new Error("cbor_duplicate_key");
          out.set(key, item(depth + 1));
        }
        return out;
      }
      case 6:
        readArgument(info);
        return item(depth + 1);
      default:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        throw new Error("cbor_unsupported_simple");
    }
  };

  const value = item(0);
  return { value, end: pos };
}

export function asMap(value: CborValue | undefined, what: string): Map<CborValue, CborValue> {
  if (!(value instanceof Map)) throw new Error(`cbor_expected_map_${what}`);
  return value;
}

export function asBytes(value: CborValue | undefined, what: string): Uint8Array {
  if (!(value instanceof Uint8Array)) throw new Error(`cbor_expected_bytes_${what}`);
  return value;
}
