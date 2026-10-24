import { z } from "zod";

const nonEmptyString = z.string().min(1);
const isoTimestamp = z.string().datetime({ precision: 3 });

export type SystemRequestJsonValue =
  | string
  | number
  | boolean
  | null
  | SystemRequestJsonValue[]
  | { [key: string]: SystemRequestJsonValue };

export const systemRequestJsonValueSchema: z.ZodType<SystemRequestJsonValue> = z.lazy(() =>
  z.union([
    z.string(),
    z.number().finite(),
    z.boolean(),
    z.null(),
    z.array(systemRequestJsonValueSchema),
    z.record(z.string(), systemRequestJsonValueSchema),
  ]),
);

export const systemRequestJsonRecordSchema = z.record(
  z.string(),
  systemRequestJsonValueSchema,
);

/** Durable request DTO implemented by migration 0033's repository. */
export const systemRequestDtoSchema = z
  .object({
    requestId: nonEmptyString,
    userId: nonEmptyString,
    sessionId: nonEmptyString,
    runId: nonEmptyString,
    kind: z.enum(["approval", "sampling", "elicitation"]),
    safePayload: systemRequestJsonRecordSchema,
    sensitive: z.boolean(),
    status: z.enum(["pending", "resolved", "expired", "cancelled"]),
    expiresAt: isoTimestamp,
    response: systemRequestJsonRecordSchema.nullable(),
    version: z.number().int().positive(),
  })
  .strict()
  .superRefine((request, context) => {
    if (request.sensitive && request.response !== null) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["response"],
        message: "Sensitive response plaintext is never exposed or durably stored.",
      });
    }
    if (request.status === "pending" && request.response !== null) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["response"],
        message: "A pending request cannot already contain a response.",
      });
    }
  });
export type SystemRequestDto = z.infer<typeof systemRequestDtoSchema>;

/** Response receipt; version is the answered request version before CAS increment. */
export const systemResponseDtoSchema = z
  .object({
    requestId: nonEmptyString,
    userId: nonEmptyString,
    version: z.number().int().positive(),
    response: systemRequestJsonRecordSchema.nullable(),
    clientResponseId: nonEmptyString,
    createdAt: isoTimestamp,
  })
  .strict();
export type SystemResponseDto = z.infer<typeof systemResponseDtoSchema>;

/**
 * Client attempt used by replay/conflict examples. userId is server-derived;
 * requestId is removed by the HTTP adapter when it moves into the route path.
 */
export const systemResponseAttemptSchema = z
  .object({
    requestId: nonEmptyString,
    version: z.number().int().positive(),
    response: systemRequestJsonRecordSchema,
    clientResponseId: nonEmptyString,
  })
  .strict();
export type SystemResponseAttempt = z.infer<typeof systemResponseAttemptSchema>;

export const systemRequestsFixtureV1Schema = z
  .object({
    contractVersion: z.literal(1),
    requests: z
      .object({
        pendingApproval: systemRequestDtoSchema,
        sensitiveElicitation: systemRequestDtoSchema,
      })
      .strict(),
    responseReceipt: systemResponseDtoSchema,
    identicalReplay: z
      .object({
        attempt: systemResponseAttemptSchema,
        receipt: systemResponseDtoSchema,
      })
      .strict(),
    versionConflict: z
      .object({
        attempt: systemResponseAttemptSchema,
        currentVersion: z.number().int().positive(),
        error: z
          .object({
            code: z.literal("version_conflict"),
            message: nonEmptyString,
          })
          .strict(),
      })
      .strict(),
  })
  .strict();
export type SystemRequestsFixtureV1 = z.infer<typeof systemRequestsFixtureV1Schema>;
