// The LLM gateway (ai-design §3): one interface, one Vertex implementation, a fake for tests.
// Swapping providers means a second implementation, not edits across features.
//
// Vertex `generateContent`, read 2026-10-26 and probed against suskii-staging the same day:
//   POST https://{location}-aiplatform.googleapis.com/v1/projects/{p}/locations/{location}/
//        publishers/google/models/{model}:generateContent        (host `aiplatform.googleapis.com`
//        for `global`), OAuth2 scope cloud-platform.
//   gemini-3.5-flash serves in europe-west2 and global; tools and a JSON responseSchema work in one
//   request; `thinkingConfig.thinkingBudget: 0` turns thinking off (`thinkingLevel: LOW` does not).
// Model ids come from configuration (ADR-0006): this file names none.

export interface Route {
  model: string;
  location: string;
  thinking_budget?: number;
}

export interface Part {
  text?: string;
  functionCall?: { name: string; args?: Record<string, unknown>; id?: string };
  functionResponse?: { name: string; response: Record<string, unknown>; id?: string };
  thoughtSignature?: string;
  [key: string]: unknown;
}

export interface Content {
  role: "user" | "model";
  parts: Part[];
}

export interface FunctionDeclaration {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface GenerateRequest {
  system: string;
  contents: Content[];
  tools?: FunctionDeclaration[];
  responseSchema?: Record<string, unknown>;
  maxOutputTokens: number;
  temperature: number;
}

export interface Usage {
  input: number;
  output: number;
  thought: number;
}

export interface GenerateResult {
  parts: Part[];
  finishReason: string;
  usage: Usage;
  model: string;
  location: string;
}

export interface LlmGateway {
  generate(request: GenerateRequest, routes: Route[], signal?: AbortSignal): Promise<GenerateResult>;
}

/** Every route failed, or there were none. The caller degrades to the form (ai-design §6.6). */
export class LlmUnavailable extends Error {
  constructor(readonly attempts: string[]) {
    super(`llm unavailable: ${attempts.join("; ") || "no route"}`);
  }
}

export interface VertexOptions {
  project: string;
  accessToken(signal?: AbortSignal): Promise<string>;
  fetch?: typeof fetch;
  /** Per attempt. A turn that has not answered in this long will not be a good turn. */
  timeoutMs?: number;
  sleep?: (ms: number) => Promise<void>;
  random?: () => number;
}

const RETRYABLE = new Set([429, 500, 502, 503, 504]);

export class VertexGemini implements LlmGateway {
  private readonly fetchFn: typeof fetch;
  private readonly timeoutMs: number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly random: () => number;

  constructor(private readonly options: VertexOptions) {
    this.fetchFn = options.fetch ?? fetch;
    this.timeoutMs = options.timeoutMs ?? 12_000;
    this.sleep = options.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.random = options.random ?? Math.random;
  }

  async generate(request: GenerateRequest, routes: Route[], signal?: AbortSignal): Promise<GenerateResult> {
    const attempts: string[] = [];
    for (const route of routes) {
      // One retry with jitter on a retryable status, then the next route.
      for (let attempt = 0; attempt < 2; attempt++) {
        const outcome = await this.once(request, route, signal);
        if ("result" in outcome) return outcome.result;
        attempts.push(`${route.model}@${route.location}:${outcome.status}`);
        if (!RETRYABLE.has(outcome.status) || attempt === 1) break;
        await this.sleep(250 + Math.floor(this.random() * 500));
      }
    }
    throw new LlmUnavailable(attempts);
  }

  private async once(
    request: GenerateRequest,
    route: Route,
    signal?: AbortSignal,
  ): Promise<{ result: GenerateResult } | { status: number }> {
    const host = route.location === "global"
      ? "aiplatform.googleapis.com"
      : `${route.location}-aiplatform.googleapis.com`;
    const url = `https://${host}/v1/projects/${this.options.project}/locations/${route.location}` +
      `/publishers/google/models/${route.model}:generateContent`;

    const generationConfig: Record<string, unknown> = {
      temperature: request.temperature,
      maxOutputTokens: request.maxOutputTokens,
    };
    if (request.responseSchema) {
      generationConfig.responseMimeType = "application/json";
      generationConfig.responseSchema = request.responseSchema;
    }
    if (route.thinking_budget !== undefined) {
      generationConfig.thinkingConfig = { thinkingBudget: route.thinking_budget };
    }
    const body: Record<string, unknown> = {
      systemInstruction: { parts: [{ text: request.system }] },
      contents: request.contents,
      generationConfig,
    };
    if (request.tools?.length) body.tools = [{ functionDeclarations: request.tools }];

    const timeout = AbortSignal.timeout(this.timeoutMs);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    let response: Response;
    try {
      response = await this.fetchFn(url, {
        method: "POST",
        headers: {
          authorization: `Bearer ${await this.options.accessToken(combined)}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
        signal: combined,
      });
    } catch {
      // A timeout or a dropped connection is a 504 for the purpose of trying again.
      return { status: 504 };
    }
    if (!response.ok) {
      await response.body?.cancel();
      return { status: response.status };
    }
    const data = await response.json() as {
      candidates?: Array<{ content?: { parts?: Part[] }; finishReason?: string }>;
      usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number };
      modelVersion?: string;
    };
    const candidate = data.candidates?.[0];
    return {
      result: {
        parts: candidate?.content?.parts ?? [],
        finishReason: candidate?.finishReason ?? "UNKNOWN",
        usage: {
          input: data.usageMetadata?.promptTokenCount ?? 0,
          output: data.usageMetadata?.candidatesTokenCount ?? 0,
          thought: data.usageMetadata?.thoughtsTokenCount ?? 0,
        },
        model: data.modelVersion ?? route.model,
        location: route.location,
      },
    };
  }
}

/** Scripted replies, in order, for tests and evals that must not reach a model. */
export class FakeLlm implements LlmGateway {
  readonly requests: GenerateRequest[] = [];
  constructor(private readonly replies: Array<Part[] | Error>) {}

  generate(request: GenerateRequest, routes: Route[]): Promise<GenerateResult> {
    this.requests.push(structuredClone(request));
    const next = this.replies.shift();
    if (!next) return Promise.reject(new LlmUnavailable(["fake: no reply left"]));
    if (next instanceof Error) return Promise.reject(next);
    return Promise.resolve({
      parts: next,
      finishReason: "STOP",
      usage: { input: 100, output: 20, thought: 0 },
      model: routes[0]?.model ?? "fake",
      location: routes[0]?.location ?? "fake",
    });
  }
}
