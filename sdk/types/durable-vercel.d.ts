// `libfx/durable-vercel` (durable/vercel.mjs): sessions in Vercel's World,
// the store and queue behind Vercel Workflow, which libfx bundles.
import type { Durability } from "./libfx.cjs";

export type { Durability } from "./libfx.cjs";

/** Options for `vercel()`. */
export interface VercelOptions {
  /** How long before the function's deadline each delivery stops. Default 30000. */
  reserveMs?: number;
  /** How long a lease lasts after its worker took or last renewed it, so how long a function that died holds its session. At least 1000. Default 15000. */
  leaseMs?: number;
}

/** Keeps sessions in Vercel's World. Each worker renews a short lease while it runs, so a function that dies frees its session soon after. */
export declare function vercel(options?: VercelOptions): Durability;
