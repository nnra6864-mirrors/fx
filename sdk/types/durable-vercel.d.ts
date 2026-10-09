// `libfx/durable-vercel` (durable/vercel.mjs): sessions in Vercel's World,
// the store and queue behind Vercel Workflow, which libfx bundles.
import type { Durability } from "./libfx.cjs";

export type { Durability } from "./libfx.cjs";

/** Options for `vercel()`. */
export interface VercelOptions {
  /** How long before the function's deadline each delivery stops. Default 30000. */
  reserveMs?: number;
}

/** Keeps sessions in Vercel's World. A turn holds its session until its function's deadline. */
export declare function vercel(options?: VercelOptions): Durability;
