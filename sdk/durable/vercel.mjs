// Sessions kept in Vercel's World, the store and queue behind Vercel
// Workflow. libfx bundles that World into this module when it is packaged,
// so an app installs nothing more and ignores any copy it has.
import { getVercelOidcToken } from "@vercel/oidc";
import { createWorld } from "@workflow/world-vercel";

/**
 * Each worker holds a session until its function's deadline, and stops
 * `reserveMs` before it so the next invocation continues the turn.
 */
export function vercel({ reserveMs } = {}) {
  if (reserveMs !== undefined && !(Number.isSafeInteger(reserveMs) && reserveMs >= 0)) throw new TypeError("vercel() reserveMs must be a non-negative integer");
  return {
    [Symbol.for("libfx.durability")]: true,
    name: "vercel",
    world: () => createWorld(),
    // The deployment's own AI Gateway credential, fresh for each request.
    gatewayKey: () => getVercelOidcToken(),
    livenessKnown: false,
    // Vercel Queues keeps a message until a delivery acknowledges it.
    queueDurable: true,
    pollMs: 1000,
    ...(reserveMs === undefined ? {} : { reserveMs }),
  };
}
