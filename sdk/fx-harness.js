// fx as a harness of the durable core in durable.js: `createFxAgent` is that
// core running fx engines. Everything the core needs to know about fx is
// here; the core itself knows only the harness contract.
import { engineInternals, journalMarksWanted } from "./fx-sdk.js";

const encoder = new TextEncoder();

/**
 * The fx harness for `createDurableAgentFactory`. `createEngine(options)`
 * returns a `createFxEngine` session, and `defaultApiKey(durability)` the
 * credential when the caller passes none.
 */
export function fxHarness({ createEngine, defaultApiKey = async () => undefined }) {
  return (options) => {
    const { checkpoint, ...engineOptions } = options;
    for (const name of ["persistence", "checkpointAfterBytes", "sessionId", "inputsDurable", "toolContext"]) {
      if (Object.hasOwn(engineOptions, name)) throw new TypeError(`createFxAgent() does not accept ${name}`);
    }
    const idempotent = idempotentTools(engineOptions.tools);
    return {
      ...(checkpoint === undefined ? {} : { seed: snapshotOf(checkpointBytesOf(checkpoint)) }),
      async open({ sessionId, store, context, durability }) {
        const apiKey = engineOptions.apiKey ?? await defaultApiKey(durability);
        const engine = await createEngine({
          ...engineOptions,
          ...(apiKey === undefined ? {} : { apiKey }),
          sessionId,
          // The core folds the session from the marks on each record.
          persistence: { ...store, [journalMarksWanted]: true },
          inputsDurable: true,
          // A checkpoint at every turn end; where a turn yields the core
          // saves one itself before it lets the session go.
          checkpointAfterBytes: 0,
          ...(context === undefined || context === null ? {} : { toolContext: context }),
        });
        return fxSession(engine, idempotent);
      },
    };
  };
}

// The engine reports a fenced write as the cause of the append that failed;
// the core knows a fence by its own `FX_FENCED` code.
const unwrapFence = (error) => (error?.cause?.code === "FX_FENCED" ? error.cause : error);

function fxTurn(turn) {
  const result = turn.result.catch((error) => { throw unwrapFence(error); });
  void result.catch(() => {});
  return {
    result,
    steer: (text, id) => turn.steer(text, id),
    cancel: (options) => turn.cancel(options),
    async *[Symbol.asyncIterator]() {
      try {
        for await (const event of turn) yield event;
      } catch (error) {
        throw unwrapFence(error);
      }
    },
  };
}

function fxSession(engine, idempotent) {
  const internals = engine[engineInternals];
  return {
    prompt: (input, options) => fxTurn(engine.prompt(input, options)),
    // A call left running reruns only when running it twice is safe. Any
    // other call is never run again: the model is told it may have partly
    // run, and the turn goes on.
    resume: (options) => fxTurn(engine.resume({ ...options, onAmbiguous: (call) => (idempotent.has(call.name) ? "rerun" : undefined) })),
    get openTurn() {
      return internals.openTurn;
    },
    settled: () => internals.settled().catch((error) => { throw unwrapFence(error); }),
    saveCheckpoint: () => internals.checkpoint(),
    exportCheckpoint: () => engine.checkpoint(),
    close: () => engine.close(),
  };
}

function toolEntries(tools) {
  if (Array.isArray(tools)) return tools;
  if (tools && typeof tools === "object") return Object.entries(tools).map(([name, tool]) => ({ ...tool, name: tool?.name ?? name }));
  return [];
}

function idempotentTools(tools) {
  const names = new Set();
  for (const tool of toolEntries(tools)) if (tool?.idempotent === true && typeof tool.name === "string") names.add(tool.name);
  return names;
}

function checkpointBytesOf(value) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError("checkpoint must be bytes");
}

// A kernel checkpoint as the snapshot a session's log starts from: `FXSN`,
// version 1, then the event it covers through, the turn after it, and no
// turn id. The seed counts as the session's first event, so the engine's
// own events start at seq 2.
function snapshotOf(checkpoint) {
  const bytes = new Uint8Array(4 + 1 + 8 + 8 + 1 + checkpoint.byteLength);
  bytes.set(encoder.encode("FXSN"), 0);
  bytes[4] = 1;
  const view = new DataView(bytes.buffer);
  view.setBigUint64(5, 1n, true);
  view.setBigUint64(13, 1n, true);
  bytes[21] = 0;
  bytes.set(checkpoint, 22);
  return bytes;
}
