import { describe, expect, expectTypeOf, it } from "vitest";

import {
  contextUsageFor,
  isSafeCompactionBoundary,
  resolveModelContextProfile,
  shouldCompact,
  type CompactionActor,
  type CompactionBoundary,
  type ContextUsage,
  type ModelContextCatalogRow,
  type ModelContextProfile,
} from "./contextPolicy.js";

const configuredFallback = {
  contextLimit: 16_000,
  outputReserveTokens: 512,
  providerReserveTokens: 32,
} as const;

const catalog: readonly ModelContextCatalogRow[] = [
  {
    model_name: "fixture-small",
    model_info: {
      max_input_tokens: 1_000,
      max_output_tokens: 400,
      provider_reserve_tokens: 10,
    },
  },
  {
    model_name: "fixture-medium",
    model_info: {
      max_tokens: 32_000,
      max_output_tokens: 1_000,
      provider_reserve_tokens: 100,
    },
  },
  {
    model_name: "fixture-large",
    model_info: {
      max_input_tokens: 1_000_000,
      max_output_tokens: 128_000,
      provider_reserve_tokens: 500,
    },
  },
  {
    model_name: "auto",
    litellm_params: { model: "provider/auto-route-a" },
    model_info: {
      max_input_tokens: 8_192,
      max_output_tokens: 1_024,
      provider_reserve_tokens: 8,
    },
  },
  {
    model_name: "auto",
    litellm_params: { model: "provider/auto-route-b" },
    model_info: {
      max_input_tokens: 262_144,
      max_output_tokens: 16_384,
      provider_reserve_tokens: 64,
    },
  },
];

const safeBoundary: CompactionBoundary = {
  beforeModelRequest: true,
  toolCallsTerminal: true,
  approvalsTerminal: true,
};

const serializedRequest = {
  model: "fixture-large",
  system: [{ role: "system", content: "Keep every exact requirement." }],
  messages: [
    {
      role: "user",
      content: "Inspect this image.",
      images: [{ mimeType: "image/png", dataBase64: "aGVsbG8taW1hZ2U=" }],
    },
    {
      role: "assistant",
      content: "",
      reasoning: "Reasoning already present in the serialized conversation.",
      toolCalls: [
        { id: "call-1", name: "read_file", args: { path: "docs/example.txt" } },
      ],
    },
    {
      role: "tool",
      toolCallId: "call-1",
      content: "exact tool result",
      result: { content: "structured tool result", isError: false },
    },
  ],
  tools: [
    {
      name: "read_file",
      description: "Read an exact file.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  ],
  reasoning: { effort: "high" },
  stream: true,
};

const serializedRequestFallback = { imageTokenUpperBound: 8_192 } as const;

describe("per-model context profiles", () => {
  it("exports the exact Task 9 profile, usage, and actor contracts", () => {
    expectTypeOf<ModelContextProfile>().toEqualTypeOf<{
      model: string;
      contextLimit: number;
      outputReserveTokens: number;
      providerReserveTokens: number;
    }>();
    expectTypeOf<ContextUsage>().toEqualTypeOf<{
      usageSource: "measured" | "deterministic_fallback";
      beforeTokens: number;
    }>();
    expectTypeOf<CompactionActor>().toEqualTypeOf<{
      sessionId: string;
      rootTaskRunId: string;
      logicalWorkerId: string | null;
      attemptId: string | null;
      kind: "main" | "worker";
    }>();
  });

  it("resolves exact configured limits and effective reserves for several models", () => {
    const expected: Record<string, ModelContextProfile> = {
      "fixture-small": {
        model: "fixture-small",
        contextLimit: 1_000,
        outputReserveTokens: 400,
        providerReserveTokens: 10,
      },
      "fixture-medium": {
        model: "fixture-medium",
        contextLimit: 32_000,
        outputReserveTokens: 1_000,
        providerReserveTokens: 100,
      },
      "fixture-large": {
        model: "fixture-large",
        contextLimit: 1_000_000,
        outputReserveTokens: 128_000,
        providerReserveTokens: 500,
      },
    };

    for (const model of Object.keys(expected)) {
      expect(
        resolveModelContextProfile({ model, catalog, fallback: configuredFallback }),
      ).toEqual(expected[model]);
    }
  });

  it("uses the request output cap as the effective reserve, bounded by exact model metadata", () => {
    expect(
      resolveModelContextProfile({
        model: "fixture-medium",
        catalog,
        fallback: configuredFallback,
        requestMaxOutputTokens: 256,
      }),
    ).toEqual({
      model: "fixture-medium",
      contextLimit: 32_000,
      outputReserveTokens: 256,
      providerReserveTokens: 100,
    });
    expect(
      resolveModelContextProfile({
        model: "fixture-small",
        catalog,
        fallback: configuredFallback,
        requestMaxOutputTokens: 900,
      }).outputReserveTokens,
    ).toBe(400);
  });

  it("uses conservative configured values when exact selected-model metadata is unknown", () => {
    expect(
      resolveModelContextProfile({
        model: "not-in-catalog",
        catalog,
        fallback: configuredFallback,
      }),
    ).toEqual({ model: "not-in-catalog", ...configuredFallback });

    const partialCatalog: readonly ModelContextCatalogRow[] = [
      {
        model_name: "partial-model",
        model_info: {
          max_input_tokens: 0,
          max_tokens: -1,
          max_output_tokens: 1.5,
          provider_reserve_tokens: -10,
        },
      },
    ];
    expect(
      resolveModelContextProfile({
        model: "partial-model",
        catalog: partialCatalog,
        fallback: configuredFallback,
      }),
    ).toEqual({ model: "partial-model", ...configuredFallback });
    expect(
      resolveModelContextProfile({
        model: "catalog-unavailable",
        catalog: null,
        fallback: configuredFallback,
      }),
    ).toEqual({ model: "catalog-unavailable", ...configuredFallback });
  });

  it("does not guess a deployment when an auto alias has no resolved actual model", () => {
    expect(
      resolveModelContextProfile({ model: "auto", catalog, fallback: configuredFallback }),
    ).toEqual({ model: "auto", ...configuredFallback });
  });

  it("re-resolves the actual model when an auto route changes", () => {
    const first = resolveModelContextProfile({
      model: "provider/auto-route-a",
      catalog,
      fallback: configuredFallback,
    });
    const second = resolveModelContextProfile({
      model: "provider/auto-route-b",
      catalog,
      fallback: configuredFallback,
    });
    const firstAgain = resolveModelContextProfile({
      model: "provider/auto-route-a",
      catalog,
      fallback: configuredFallback,
    });

    expect(first).toEqual({
      model: "provider/auto-route-a",
      contextLimit: 8_192,
      outputReserveTokens: 1_024,
      providerReserveTokens: 8,
    });
    expect(second).toEqual({
      model: "provider/auto-route-b",
      contextLimit: 262_144,
      outputReserveTokens: 16_384,
      providerReserveTokens: 64,
    });
    expect(firstAgain).toEqual(first);
  });
});

describe("context pressure and safe boundaries", () => {
  it("does not fold at 79% and folds at exact 80% for each model and usage source", () => {
    const cases: Array<{
      profile: ModelContextProfile;
      usageSource: ContextUsage["usageSource"];
      at79: number;
      at80: number;
    }> = [
      {
        profile: {
          model: "fixture-small",
          contextLimit: 1_000,
          outputReserveTokens: 100,
          providerReserveTokens: 0,
        },
        usageSource: "measured",
        at79: 790,
        at80: 800,
      },
      {
        profile: {
          model: "fixture-medium",
          contextLimit: 32_000,
          outputReserveTokens: 1_000,
          providerReserveTokens: 100,
        },
        usageSource: "deterministic_fallback",
        at79: 25_280,
        at80: 25_600,
      },
      {
        profile: {
          model: "fixture-large",
          contextLimit: 128_000,
          outputReserveTokens: 4_000,
          providerReserveTokens: 500,
        },
        usageSource: "measured",
        at79: 101_120,
        at80: 102_400,
      },
      {
        profile: {
          model: "fixture-million",
          contextLimit: 1_000_000,
          outputReserveTokens: 128_000,
          providerReserveTokens: 1_000,
        },
        usageSource: "deterministic_fallback",
        at79: 790_000,
        at80: 800_000,
      },
    ];

    for (const row of cases) {
      expect(
        shouldCompact({
          profile: row.profile,
          usage: { usageSource: row.usageSource, beforeTokens: row.at79 },
          boundary: safeBoundary,
        }),
        `${row.profile.model} at 79%`,
      ).toBe(false);
      expect(
        shouldCompact({
          profile: row.profile,
          usage: { usageSource: row.usageSource, beforeTokens: row.at80 },
          boundary: safeBoundary,
        }),
        `${row.profile.model} at exact 80%`,
      ).toBe(true);
    }
  });

  it("preserves exact below-80 and exact-80 decisions near MAX_SAFE_INTEGER", () => {
    const beforeTokens = 7_205_759_403_712_792;
    const below80Limit = 9_007_199_254_640_991;
    const exact80Limit = 9_007_199_254_640_990;
    const profile = {
      model: "near-max-safe",
      outputReserveTokens: 0,
      providerReserveTokens: 0,
    };

    // Independently checked integer identities: the first left side is exactly
    // 80 below the right side; the second comparison is exactly equal.
    expect(BigInt(beforeTokens) * 100n).toBe(BigInt(below80Limit) * 80n - 80n);
    expect(BigInt(beforeTokens) * 100n).toBe(BigInt(exact80Limit) * 80n);
    expect(
      shouldCompact({
        profile: { ...profile, contextLimit: below80Limit },
        usage: { usageSource: "deterministic_fallback", beforeTokens },
        boundary: safeBoundary,
      }),
    ).toBe(false);
    expect(
      shouldCompact({
        profile: { ...profile, contextLimit: exact80Limit },
        usage: { usageSource: "deterministic_fallback", beforeTokens },
        boundary: safeBoundary,
      }),
    ).toBe(true);
  });

  it("allows compaction only before a model request with tools and approvals terminal", () => {
    expect(isSafeCompactionBoundary(safeBoundary)).toBe(true);
    expect(
      isSafeCompactionBoundary({ ...safeBoundary, beforeModelRequest: false }),
    ).toBe(false);
    expect(isSafeCompactionBoundary({ ...safeBoundary, toolCallsTerminal: false })).toBe(
      false,
    );
    expect(isSafeCompactionBoundary({ ...safeBoundary, approvalsTerminal: false })).toBe(
      false,
    );
  });

  it("never folds mid-tool-call or mid-approval even at full context pressure", () => {
    const input = {
      profile: {
        model: "fixture-small",
        contextLimit: 1_000,
        outputReserveTokens: 100,
        providerReserveTokens: 0,
      },
      usage: { usageSource: "measured", beforeTokens: 1_000 },
    } as const;

    expect(shouldCompact({ ...input, boundary: safeBoundary })).toBe(true);
    expect(
      shouldCompact({
        ...input,
        boundary: { ...safeBoundary, toolCallsTerminal: false },
      }),
    ).toBe(false);
    expect(
      shouldCompact({
        ...input,
        boundary: { ...safeBoundary, approvalsTerminal: false },
      }),
    ).toBe(false);
    expect(
      shouldCompact({
        ...input,
        boundary: { ...safeBoundary, beforeModelRequest: false },
      }),
    ).toBe(false);
  });
});

describe("honest whole-request context usage", () => {
  it("accounts for the complete UTF-8 serialized request plus configured image and framing bounds", () => {
    const serialized = JSON.stringify(serializedRequest);
    const messageFrames = 4 * (serializedRequest.system.length + serializedRequest.messages.length);
    const expected =
      Buffer.byteLength(serialized, "utf8") +
      4 +
      messageFrames +
      serializedRequestFallback.imageTokenUpperBound;

    expect(contextUsageFor(serializedRequest, undefined, serializedRequestFallback)).toEqual({
      usageSource: "deterministic_fallback",
      beforeTokens: expected,
    });
    expect(contextUsageFor(serializedRequest, undefined, serializedRequestFallback)).toEqual(
      contextUsageFor(serializedRequest, undefined, serializedRequestFallback),
    );
  });

  it("charges system, messages, tools, results, reasoning, and images instead of text only", () => {
    const full = contextUsageFor(
      serializedRequest,
      undefined,
      serializedRequestFallback,
    ).beforeTokens;
    const reductions: Array<(request: typeof serializedRequest) => void> = [
      (request) => {
        request.system = [];
      },
      (request) => {
        request.messages = [];
      },
      (request) => {
        request.tools = [];
      },
      (request) => {
        Reflect.deleteProperty(request.messages[2]!, "result");
      },
      (request) => {
        Reflect.deleteProperty(request.messages[1]!, "reasoning");
      },
      (request) => {
        Reflect.deleteProperty(request, "reasoning");
      },
      (request) => {
        Reflect.deleteProperty(request.messages[0]!, "images");
      },
    ];

    for (const reduce of reductions) {
      const stripped = structuredClone(serializedRequest);
      reduce(stripped);
      expect(
        contextUsageFor(stripped, undefined, serializedRequestFallback).beforeTokens,
      ).toBeLessThan(full);
    }
  });

  it("uses provider input tokens only when exact measured usage is available", () => {
    expect(contextUsageFor(serializedRequest, 12_345)).toEqual({
      usageSource: "measured",
      beforeTokens: 12_345,
    });
  });

  it("falls back honestly when measured metadata is absent or invalid", () => {
    const fallback = contextUsageFor(
      serializedRequest,
      undefined,
      serializedRequestFallback,
    );
    expect(fallback.usageSource).toBe("deterministic_fallback");
    expect(contextUsageFor(serializedRequest, null, serializedRequestFallback)).toEqual(
      fallback,
    );
    expect(
      contextUsageFor(serializedRequest, undefined, serializedRequestFallback),
    ).toEqual(fallback);
    for (const invalid of [Number.NaN, Number.POSITIVE_INFINITY, -1, 1.5]) {
      expect(contextUsageFor(serializedRequest, invalid, serializedRequestFallback)).toEqual(
        fallback,
      );
    }
  });

  it("uses the one-token-per-serialized-byte adversarial bound for dense text", () => {
    const denseRequest = {
      system: [{ role: "system", content: `${"!".repeat(257)}${"\u0000".repeat(31)}` }],
      messages: [
        { role: "user", content: "😀\n\t\"\\".repeat(129) },
        { role: "assistant", content: "", reasoning: "?".repeat(1_025) },
      ],
      tools: [
        {
          name: "x",
          description: "~`.;:!@#$%^&*()[]{}<>|/\\".repeat(41),
          parameters: { type: "object", properties: {} },
        },
      ],
    };
    const serializedBytes = Buffer.byteLength(JSON.stringify(denseRequest), "utf8");
    const independentByteFallbackBound = serializedBytes + 4 + 4 * 3;

    expect(contextUsageFor(denseRequest)).toEqual({
      usageSource: "deterministic_fallback",
      beforeTokens: independentByteFallbackBound,
    });
    expect(independentByteFallbackBound).toBeGreaterThan(
      Math.ceil(serializedBytes / 4) + 4 + 4 * 3,
    );
  });

  it("adds a configured conservative bound for every provider image shape", () => {
    const imageRequest = {
      system: [],
      messages: [
        {
          role: "user",
          content: "internal image",
          images: [{ mimeType: "image/png", dataBase64: "AA==" }],
        },
        {
          role: "user",
          content: [
            {
              type: "image_url",
              image_url: { url: "data:image/png;base64,AA==" },
            },
          ],
        },
        {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: "image/png", data: "AA==" },
            },
          ],
        },
      ],
    };
    const imageTokenUpperBound = 2_048;
    const independentBound =
      Buffer.byteLength(JSON.stringify(imageRequest), "utf8") +
      4 +
      4 * 3 +
      3 * imageTokenUpperBound;

    expect(
      contextUsageFor(imageRequest, undefined, { imageTokenUpperBound }),
    ).toEqual({
      usageSource: "deterministic_fallback",
      beforeTokens: independentBound,
    });
  });

  it("fails closed instead of inventing an image token bound", () => {
    const request = {
      messages: [
        {
          role: "user",
          content: [{ type: "image_url", image_url: { url: "data:image/png;base64,AA==" } }],
        },
      ],
    };

    expect(contextUsageFor(request)).toEqual({
      usageSource: "deterministic_fallback",
      beforeTokens: Number.MAX_SAFE_INTEGER,
    });
  });

  it("keeps the next request within the real limit with output and provider reserves", async () => {
    const { nextRequestWithinLimit } = await import("./contextPolicy.js");
    expect(nextRequestWithinLimit).toBeTypeOf("function");
    const request = {
      messages: [
        {
          role: "user",
          content: "dense !!!!",
          images: [{ mimeType: "image/png", dataBase64: "AA==" }],
        },
      ],
    };
    const usage = contextUsageFor(request, undefined, { imageTokenUpperBound: 2_048 });
    const profile = {
      model: "reserved-image-model",
      contextLimit: usage.beforeTokens + 1_024 + 256,
      outputReserveTokens: 1_024,
      providerReserveTokens: 256,
    };

    expect(nextRequestWithinLimit({ profile, usage })).toBe(true);
    expect(
      nextRequestWithinLimit({
        profile: { ...profile, contextLimit: profile.contextLimit - 1 },
        usage,
      }),
    ).toBe(false);

    const unknownImageUsage = contextUsageFor(request);
    expect(
      nextRequestWithinLimit({
        profile: {
          ...profile,
          contextLimit: Number.MAX_SAFE_INTEGER,
          outputReserveTokens: 0,
          providerReserveTokens: 0,
        },
        usage: unknownImageUsage,
      }),
    ).toBe(false);
  });
});
