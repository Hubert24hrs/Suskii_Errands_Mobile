import { assertEquals } from "@std/assert";
import { AccessRefusedError, createDocumentUrlHandler, type DocumentUrlDeps } from "./handler.ts";

console.log = () => {};
console.error = () => {};

const NOW = Date.UTC(2026, 9, 13, 12, 0, 0);
const REF = "a1111111-1111-4111-8111-111111111111/id-front.jpg";

function deps(overrides: Partial<DocumentUrlDeps> = {}) {
  const calls: string[] = [];
  const d: DocumentUrlDeps = {
    requestAccess(ref, reason) {
      calls.push(`access:${ref}:${reason}`);
      return Promise.resolve(ref);
    },
    sign(path, ttl) {
      calls.push(`sign:${path}:${ttl}`);
      return Promise.resolve(`https://storage.test/kyc-docs/${path}?token=t`);
    },
    now: () => NOW,
    log: () => {},
    ...overrides,
  };
  return { d, calls };
}

function post(body: unknown): Request {
  return new Request("http://local/kyc-document-url", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

Deno.test("access is requested, as the officer, before anything is signed", async () => {
  const { d, calls } = deps();
  const res = await createDocumentUrlHandler(d)(post({ upload_ref: REF, reason_code: "kyc_review" }));
  assertEquals(res.status, 200);
  assertEquals(calls, [`access:${REF}:kyc_review`, `sign:${REF}:60`]);
  assertEquals(await res.json(), {
    url: `https://storage.test/kyc-docs/${REF}?token=t`,
    expires_at: "2026-10-13T12:01:00.000Z",
  });
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("a refusal from the database signs nothing and keeps its code", async () => {
  const { d, calls } = deps({
    requestAccess: () => Promise.reject(new AccessRefusedError("ERR_PERMISSION_DENIED")),
  });
  const res = await createDocumentUrlHandler(d)(post({ upload_ref: REF, reason_code: "kyc_review" }));
  assertEquals(res.status, 403);
  assertEquals(await res.json(), { error: { code: "ERR_PERMISSION_DENIED" } });
  assertEquals(calls.filter((c) => c.startsWith("sign")), []);
});

Deno.test("a stale second factor is a 401 the console answers with a fresh code", async () => {
  const { d, calls } = deps({
    requestAccess: () => Promise.reject(new AccessRefusedError("ERR_REAUTH_REQUIRED")),
  });
  const res = await createDocumentUrlHandler(d)(post({ upload_ref: REF, reason_code: "kyc_review" }));
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { error: { code: "ERR_REAUTH_REQUIRED" } });
  assertEquals(calls.filter((c) => c.startsWith("sign")), []);
});

Deno.test("a path that is not one file in one user's folder is refused before the database", async () => {
  const bad = [
    { upload_ref: "../a1111111-1111-4111-8111-111111111111/x.jpg", reason_code: "kyc_review" },
    { upload_ref: "a1111111-1111-4111-8111-111111111111/../b/x.jpg", reason_code: "kyc_review" },
    { upload_ref: "a1111111-1111-4111-8111-111111111111/", reason_code: "kyc_review" },
    { upload_ref: "not-a-user/x.jpg", reason_code: "kyc_review" },
    { upload_ref: REF, reason_code: "Because I want to" },
    { upload_ref: REF },
  ];
  for (const body of bad) {
    const { d, calls } = deps();
    const res = await createDocumentUrlHandler(d)(post(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals(calls, []);
  }
});

Deno.test("only POST, and only JSON", async () => {
  const { d } = deps();
  assertEquals((await createDocumentUrlHandler(d)(new Request("http://local/", { method: "GET" }))).status, 405);
  assertEquals((await createDocumentUrlHandler(d)(post("{not json"))).status, 400);
});

Deno.test("the database must answer with the path it audited", async () => {
  const { d, calls } = deps({ requestAccess: () => Promise.resolve("a1111111-1111-4111-8111-111111111111/other.jpg") });
  const res = await createDocumentUrlHandler(d)(post({ upload_ref: REF, reason_code: "kyc_review" }));
  assertEquals(res.status, 500);
  assertEquals(calls.filter((c) => c.startsWith("sign")), []);
});

Deno.test("a signing failure is an internal error, not a partial answer", async () => {
  const { d } = deps({ sign: () => Promise.reject(new Error("storage down")) });
  const res = await createDocumentUrlHandler(d)(post({ upload_ref: REF, reason_code: "kyc_review" }));
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { error: { code: "ERR_INTERNAL" } });
});
