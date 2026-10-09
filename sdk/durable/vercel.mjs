// Sessions kept in Vercel's World, the store and queue behind Vercel
// Workflow. libfx bundles that World into this module when it is packaged,
// so an app installs nothing more and ignores any copy it has.
import { getVercelOidcToken } from "@vercel/oidc";
import { createWorld } from "@workflow/world-vercel";
import { world } from "./world.mjs";

/**
 * Each worker renews its lease while it runs, so a session whose worker
 * died frees `leaseMs` after its last renewal. A worker stops `reserveMs`
 * before its function's deadline, and the next invocation continues the
 * turn.
 */
export function vercel({ reserveMs, leaseMs } = {}) {
  return world(() => createWorld(), {
    name: "vercel",
    // The deployment's own AI Gateway credential, fresh for each request.
    gatewayKey: () => getVercelOidcToken(),
    livenessKnown: false,
    // Vercel Queues keeps a message until a delivery acknowledges it.
    queueDurable: true,
    pollMs: 1000,
    reserveMs,
    leaseMs,
  });
}
