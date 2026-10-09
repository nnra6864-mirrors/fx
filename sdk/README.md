# libfx

libfx is the agent from [fx](https://github.com/vercel-labs/fx), the open source coding agent from Vercel Labs, as a JavaScript library. You give it a model, instructions and your own tools, and it runs the conversation: streaming, tool calls, retries, steering and images. It's the same Zig engine that runs fx in your terminal, built as a native addon and as WebAssembly.

Sessions are durable. libfx records each step of a turn as it happens, so when a server crashes, a function hits its time limit or you redeploy in the middle of a reply, the next process picks the turn up where it stopped. On Vercel, that takes one route and one line of `vercel.json`.

```sh
npm install libfx
```

```js
import { createFxAgent } from "libfx";

const agent = createFxAgent({
  model: "anthropic/claude-haiku-5.5",
  instructions: "Answer in one paragraph.",
});

const turn = agent.session().prompt("What is an agent loop?");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

await agent.close();
```

Model calls go through [AI Gateway](https://vercel.com/docs/ai-gateway), so any model it lists works. Set `AI_GATEWAY_API_KEY` on your machine. On Vercel, libfx uses the deployment's OIDC token and there's no key to manage.

Importing libfx doesn't touch the network, read files or start processes, and `createFxAgent()` returns right away. Nothing loads until a session runs its first turn.

The full documentation is at [fx.sh/docs/lib](https://fx.sh/docs/lib).

## Features

- [Streams](https://fx.sh/docs/lib/prompts) text, reasoning and tool calls as the agent works
- Runs your JavaScript functions as [tools](https://fx.sh/docs/lib/tools), along with [MCP](https://fx.sh/docs/lib/mcp) clients and [skills](https://fx.sh/docs/lib/skills)
- Keeps [sessions](https://fx.sh/docs/lib/durability) going through crashes, deploys and function timeouts
- Reconnects to a running turn from any server, starting at the last event you saw
- [Steers](https://fx.sh/docs/lib/steering) a turn while it runs
- Takes [images](https://fx.sh/docs/lib/images) in prompts and tool results
- Gives each conversation its own model, instructions and context
- Uses a native addon on macOS and Linux, and WebAssembly everywhere else, including browsers
- Puts the [fx terminal](https://fx.sh/docs/lib/webassembly#embed-the-terminal) in a web page
- Ships TypeScript types for every entry point, with no runtime dependencies

## Sessions

An agent is configuration. Create one per server and open a session per conversation:

```js
const turn = agent.session().prompt("Plan the migration.");
const { sessionId } = await turn.accepted;

// Later, from any process that creates the same agent:
agent.session(sessionId).prompt("Start with the schema.");
```

A session runs one turn at a time. A prompt that arrives while a turn is running waits behind it, even when it reaches a different server. A turn runs to the end whether or not anyone reads it; stop it with `session.cancel()` or the prompt's `signal`. `session.steer(text)` adds guidance to the running turn at its next model request.

If a client might send the same request twice, give the prompt a `messageId`. A prompt with an id the session already accepted runs nothing and follows the original turn.

Each conversation can bring its own settings. They apply to the turns that call starts:

```js
agent.session(sessionId, {
  model: { id: "anthropic/claude-opus-5.5", effort: "high" },
  instructions: "You review pull requests.",
  context: { userId }, // handed to every tool call
});
```

### Streaming to a browser

`turn.readable` is the turn as newline-delimited JSON, ready to return from a route. Every line has a `cursor`. `session.stream(cursor)` replays everything from that point and stays open, so a client that loses its connection can reconnect to any server and carry on.

```js
// app/api/chat/route.js
import { agent } from "@/lib/agent";

export async function POST(request) {
  const sessionId = new URL(request.url).searchParams.get("sessionId") ?? undefined;
  // Check that the caller may use this session.
  const turn = agent.session(sessionId).prompt(await request.text());
  return new Response(turn.readable);
}

export async function GET(request) {
  const params = new URL(request.url).searchParams;
  const sessionId = params.get("sessionId");
  if (!sessionId) return new Response("sessionId is required", { status: 400 });
  // Same check as POST.
  const stream = agent.session(sessionId).stream(Number(params.get("cursor") ?? 0));
  return new Response(stream);
}
```

## Durability

libfx stores a prompt before it reports the prompt as accepted, and it stores each step of a turn while the turn runs. If the process running a turn dies, the next process that gets work for that session continues the turn from its last step. The model is told the turn was interrupted, so it can check what happened before going on.

Where sessions live depends on where your code runs, and libfx picks for you:

| Where | Durability | Sessions live in |
| --- | --- | --- |
| Vercel | `vercel()` | Vercel's [Workflow World](https://workflow-sdk.dev/worlds) |
| Node.js | `local()` | files in `$TMPDIR/libfx/sessions`, or `FX_SESSIONS_DIR` |
| Browsers | `memory()` | the page's memory |

To choose yourself, pass `durability`:

```js
import { createFxAgent, memory } from "libfx";
import { local } from "libfx/durable-local";

createFxAgent({ durability: local({ dir: ".fx/sessions" }) });
createFxAgent({ durability: memory() }); // nothing survives the process
```

To keep sessions in your own database, create a World such as Workflow's Postgres World and pass it to `world()` from `libfx/durable-world`. The [durability guide](https://fx.sh/docs/lib/durability) shows how.

With `local()` and `vercel()`, a session id is a Workflow run id. Take it from `turn.accepted` or `await agent.newSessionId()` instead of making one up.

A session stores only the conversation. Every process passes its own model, credentials, tools, MCP clients and skills when it creates the agent.

### On Vercel

Add a route for libfx's queue deliveries:

```js
// app/api/libfx/route.js
import { agent } from "@/lib/agent";

export const POST = agent.wakeHandler();
```

Then subscribe it to libfx's topic in `vercel.json`:

```json
{
  "functions": {
    "app/api/libfx/route.js": {
      "experimentalTriggers": [{ "type": "queue/v2beta", "topic": "__libfx_wkf_workflow_session" }]
    }
  }
}
```

That's all. `prompt()` sends each turn to Vercel Queues, and this route runs it. When a turn gets close to the function's time limit, libfx saves it and the next invocation continues it. When a function dies mid-turn, its session frees about 15 seconds after it last checked in, and the turn carries on in a new invocation. `vercel({ reserveMs, leaseMs })` from `libfx/durable-vercel` changes both timings.

### Tools with side effects

When a process dies during a tool call, libfx can't know whether the call finished. Mark a tool `idempotent: true` if running it twice is harmless, like a lookup, and it runs again when the turn continues. Any other tool never runs twice on its own: the model gets an error saying the call may have partly run, and decides whether to check, try again or ask the user.

Each call also gets an `executionId` that stays the same when the call runs again. Pass it to the service your tool calls as an idempotency key, and a repeated call won't change anything twice.

## Tools

```js
const agent = createFxAgent({
  tools: [{
    name: "get_order",
    description: "Look up an order by id.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    idempotent: true,
    async execute({ id }, { signal, executionId, context }) {
      return orders.get(id, { signal });
    },
  }],
});
```

`execute` gets a `signal` that aborts when the turn is cancelled, the call's `executionId`, and the session's `context`. Return any JSON value, or `{ type: "libfx.tool-result", text, images }` to return images.

On the native backend, the calls from one model response run at the same time. Mark a tool `writes: true` to keep it from overlapping with others. Add `{ name: "web_search", providerExecuted: true }` for AI Gateway's web search, which runs at the provider instead of in your code.

### MCP and skills

```js
import { createMcpAdapter } from "libfx/mcp";
import { createSkillsAdapter } from "libfx/skills";
import { loadSkillFile } from "libfx/skills/node";

const mcp = await createMcpAdapter(client, { prefix: "github_" }); // your MCP SDK client
const skills = createSkillsAdapter([await loadSkillFile("./skills/review/SKILL.md")]);

const agent = createFxAgent({
  tools: [...mcp.tools, ...skills.tools],
  instructions: [mcp.instructions, skills.instructions].join("\n\n"),
});

// When you're done:
await agent.close();
await mcp.close();
```

libfx doesn't own the MCP connection. You create the client, handle its auth and close it after the agent.

## Models

```js
createFxAgent({ model: { id: "anthropic/claude-opus-5.5", effort: "low", fast: true } });
```

`effort` and `fast` mean the same as the fx CLI's `--effort` and `--fast` flags. `ultrafast: true` asks for the faster, more expensive service tier on models that offer it. A setting the model doesn't support fails with an error whose `code` names it, such as `LIBFX_MODEL_UNSUPPORTED_EFFORT`.

`listModels({ apiKey })` returns the Gateway's language models. Behind a proxy that only forwards chat requests, pass the catalog yourself as `modelCatalog`, and the agent won't fetch it.

`onEvent` receives diagnostics apart from the model's output: request timing, and session events such as `session.deadline` and `checkpoint.mismatch`. Credentials never appear in them.

## One conversation, no sessions

`createFxEngine()` is the engine under the agent: one conversation in the memory of the process that runs it, with no queue and no session store. Use it for a single request, or to keep the conversation in storage of your own.

```js
import { createFxEngine } from "libfx";

const engine = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model: "anthropic/claude-haiku-5.5" });

const turn = engine.prompt("Summarize this file.");
for await (const event of turn) {
  // ...
}

const checkpoint = await engine.checkpoint(); // opaque bytes
const restored = await createFxEngine({ apiKey, model, checkpoint });
```

Pass a `persistence` store instead, and the engine records the conversation as it runs, so a new engine can `resume()` a turn the last process left open. A store needs two methods and can add a third. The bytes are opaque, so it never has to understand them:

```ts
interface Persistence {
  load(): Promise<{
    checkpoint?: { data: Uint8Array; through: string };
    journal?: Iterable<JournalRecord> | AsyncIterable<JournalRecord>;
  }>;
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array }): Promise<{ cursor: string }>;
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>;
}

interface JournalRecord {
  cursor: string;
  data: Uint8Array;
}
```

Reject an `append()` whose `expected` isn't the last stored cursor with `FxFencedError`, so two processes can't write the same conversation at once. `createMemoryPersistence()` is a reference store for tests. [Save and restore](https://fx.sh/docs/lib/checkpoints) has the details.

### Upgrading from 0.0.13

In libfx 0.0.13 and earlier, `createFxAgent()` created this engine. It now creates the durable agent, so rename those calls to `createFxEngine()`. Old code keeps running against the agent, with a few differences: breaking out of a turn's events no longer cancels it, turns have no `cancel()` or `steer()` (the session does), and `persistence` and `sessionId` throw because the durability holds the session.

## Runtimes

| Runtime | Backend |
| --- | --- |
| Node.js 20+ on macOS or Linux, x64 or arm64 | Native addon. Linux needs glibc 2.34 or newer. |
| Node.js elsewhere | WebAssembly with JSPI. Some Node versions need `--experimental-wasm-jspi`. |
| Browsers | WebAssembly with JSPI, from `libfx/browser` |
| Bun | The same as Node.js. For WebAssembly, use Bun 1.4.2 or newer. |

The default `backend: "auto"` tries native first. Pass `"native"` or `"wasm"` to require one, and call `getBackendInfo()` to see what would load without creating anything.

Next.js works in Node.js route handlers, with webpack or Turbopack, and doesn't need `serverExternalPackages`. CommonJS apps can `require("libfx")`. With TypeScript's `moduleResolution: "bundler"`, add `"node"` to `customConditions` to get the Node.js types.

## The fx terminal in a browser

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const terminal = await createFxTerminal({
  terminal: xtermAdapter(term), // an xterm.js Terminal
  env: { AI_GATEWAY_API_KEY: shortLivedKey },
});

await terminal.interactive;
```

This is the fx CLI's interface compiled to WebAssembly. Your page supplies storage for its sessions, settings and sign-in, and can give it a workspace that runs commands. See [WebAssembly](https://fx.sh/docs/lib/webassembly).

## Entry points

| Import | What's in it |
| --- | --- |
| `libfx` | `createFxAgent`, `createFxEngine`, `memory`, `listModels`, `getBackendInfo`, `createMemoryPersistence`, `FxFencedError` |
| `libfx/node` | The same, for Node.js explicitly |
| `libfx/browser` | The browser build, plus `createFxTerminal` and `xtermAdapter` |
| `libfx/wasm` | The WebAssembly SDK without packaged asset paths, so you pass `wasm` yourself |
| `libfx/durable-local`, `libfx/durable-vercel`, `libfx/durable-world` | `local()`, `vercel()` and `world()` |
| `libfx/mcp` | `createMcpAdapter` |
| `libfx/skills`, `libfx/skills/node` | `createSkillsAdapter`, and `loadSkillFile` for Node.js and Bun |

## Security

Your tools, MCP clients and skill loaders have whatever access your code gives them. libfx validates and orders their calls but grants nothing itself, and the native backend doesn't turn on fx's built-in shell or file tools. Don't put long-lived keys in browser code, and treat the `nativeAddon` and `gatewayChatUrl` options as trusted configuration.

## Contributing

libfx is developed in the [fx repository](https://github.com/vercel-labs/fx), under `sdk/`. Bug reports and pull requests are welcome. See [CONTRIBUTING.md](https://github.com/vercel-labs/fx/blob/main/CONTRIBUTING.md) to get started.

## License

[Apache-2.0](https://github.com/vercel-labs/fx/blob/main/LICENSE)
