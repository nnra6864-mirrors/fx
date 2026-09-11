# Native fx terminal backend

This example runs the complete native fx process in a server-owned sandbox. The browser renders terminal bytes; neither the agent nor its tools run in WebAssembly. No model credential is sent to the browser.

The example depends on Node.js, `ws`, and Python 3 on the backend. Python's standard-library PTY owns the native process. It also passes an inherited `FX_INTERACTION_FD` socket to fx for typed HTML interaction snapshots and actions, independently of terminal bytes. The socket requires the native interaction implementation in this branch.

## Local verification

From this directory run `npm ci`, then `node --test test.mjs`. The tests start real local shell processes, exercise reconnect, resizing, interruption, large input, authentication, and the separate interaction socket. They do not call a model or provision paid infrastructure.

## Vercel Sandbox integration

Your application's authenticated session initialization should acquire or resume its sandbox and install native fx once. The Vercel Sandbox command API supplies detached output, wait, and kill, but no interactive stdin or PTY resize. Consequently this example uploads a small broker into that existing sandbox and exposes its port.

Run the application backend with Bun to bundle the example's Node broker. Import `startVercelTerminal` from `./vercel.mjs` and pass:

```js
const connection = await startVercelTerminal({
  sandbox,
  cwd: "/vercel/sandbox/repo",
  origin: "https://your-app.example",
  sessionId: authenticatedSession.id,
  fxPath: "/vercel/sandbox/.local/bin/fx",
  env: { AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY },
  existingPorts: [3000],
});
```

`sandbox` is your existing `@vercel/sandbox` handle. Install that SDK in the application that imports this helper. `fxPath`, `cwd`, credentials, ports, and session identity come from trusted server state. Ensure Python 3 and the desired native fx binary exist in the sandbox startup image. `existingPorts` must include all currently exposed ports: the Sandbox update API replaces the list.

Store the returned connection with the owning application session. Call this function once at session initialization, never for every message or browser reconnect. Only return `connection.url` and `connection.sessionId` to the authenticated owner. The URL contains a scoped bearer capability: do not log it or expose it in analytics. The broker additionally requires an exact browser Origin. Production applications may instead forward the connection through their authenticated WebSocket proxy while preserving that Origin.

Call `connection.close()` when the application explicitly closes the native session. A browser socket disconnect only detaches its view and leaves fx running. This helper does not create, stop, or delete the sandbox; its owning application remains responsible for sandbox lifetime and billing.

## Wire protocol

All WebSocket frames are JSON. The first client frame is `{type:"attach",version:1,sessionId,cursor:0}`. The server returns `ready` with the accepted cursor, then retained output frames `{type:"output",cursor,data}` where data is base64 terminal bytes. `ready` means transport attachment; it does not assert that fx has finished startup. Native failures arrive as `exit` or `error`.

Input is `{type:"input",data:"text"}` or `{type:"input",encoding:"base64",data:"..."}` for raw bytes. Resize uses `{type:"resize",cols,rows}`; explicit interruption uses `{type:"interrupt"}`. Input is bounded to 64 KiB, dimensions to 1–1000, frames to 1 MiB, and queued input is bounded. There is one attached writer per session. Commands are never retried.

The same terminal instance may reconnect with its last rendered output cursor. A new blank terminal must request cursor zero. Replay is bounded; an expired cursor fails explicitly instead of rendering an incomplete screen or restarting the agent. The application should explain that a fresh screen cannot be recovered from the expired byte history. The broker does not currently maintain a terminal screen emulator or durable replay store.

HTML views attach with `view:"html"` and cursor zero. They receive snapshots without terminal bytes, and can attach even when byte replay has expired. Both views share the same single-writer limit.

Typed HTML actions use `{type:"interaction",action:{...}}`; server snapshots use `{type:"interaction",snapshot:{...}}`. The broker forwards native JSON without interpreting command or permission semantics. The latest native snapshot is replayed on attachment. UI policy stays in fx.
