// Sessions kept in a World the app supplies: its store, streams and queue,
// such as Workflow's Postgres World. `local()` and `vercel()` are this with
// the World libfx bundles for each.

const durabilityTag = Symbol.for("libfx.durability");

/**
 * `source` is the World, or a function that creates it. libfx starts and
 * closes a World it creates. A World passed in stays the app's: the app
 * starts it before the agent's first prompt and closes it after
 * `agent.close()`, and gives it to one agent at a time, since the agent
 * registers the World's handler for libfx's queue.
 *
 * - `livenessKnown`: `alive(lease)` answers whether a lease's holder still
 *   runs, from what `holderInfo()` put in it, so a crashed worker's session
 *   frees at once. Otherwise a lease holds until its deadline.
 * - `queueDurable`: the queue keeps a message until a delivery acknowledges
 *   it, across crashes. Otherwise `prompt()` stores the prompt first.
 * - `pollMs`: how often a waiting worker reads the session again.
 * - `maxDurationMs` and `reserveMs`: each delivery stops `reserveMs` before
 *   `maxDurationMs`, or before the World's `getRuntimeDeadline()`.
 * - `gatewayKey()`: the AI Gateway credential when the app passes none.
 */
export function world(source, options = {}) {
  const owned = typeof source === "function";
  if (!owned && !(source && typeof source === "object")) throw new TypeError("world() takes a World or a function that creates one");
  if (!options || typeof options !== "object" || Array.isArray(options)) throw new TypeError("world() options must be an object");
  const { name = "world", livenessKnown = false, queueDurable = false, pollMs, maxDurationMs, reserveMs, alive, holderInfo, gatewayKey } = options;
  if (typeof name !== "string" || name.length === 0) throw new TypeError("world() name must be a non-empty string");
  for (const [key, value] of Object.entries({ livenessKnown, queueDurable })) {
    if (typeof value !== "boolean") throw new TypeError(`${name}() ${key} must be a boolean`);
  }
  if (pollMs !== undefined && !(Number.isSafeInteger(pollMs) && pollMs > 0)) throw new TypeError(`${name}() pollMs must be a positive integer`);
  for (const [key, value] of Object.entries({ maxDurationMs, reserveMs })) {
    if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw new TypeError(`${name}() ${key} must be a non-negative integer`);
  }
  for (const [key, value] of Object.entries({ alive, holderInfo, gatewayKey })) {
    if (value !== undefined && typeof value !== "function") throw new TypeError(`${name}() ${key} must be a function`);
  }
  if (livenessKnown && !alive) throw new TypeError(`${name}() livenessKnown needs alive()`);
  return {
    [durabilityTag]: true,
    name,
    world: owned ? source : () => source,
    owned,
    livenessKnown,
    queueDurable,
    ...(pollMs === undefined ? {} : { pollMs }),
    ...(maxDurationMs === undefined ? {} : { maxDurationMs }),
    ...(reserveMs === undefined ? {} : { reserveMs }),
    ...(alive === undefined ? {} : { alive }),
    ...(holderInfo === undefined ? {} : { holderInfo }),
    ...(gatewayKey === undefined ? {} : { gatewayKey }),
  };
}
