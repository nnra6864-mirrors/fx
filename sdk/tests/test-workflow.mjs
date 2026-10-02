#!/usr/bin/env node
// libfx/workflow on a real World (@workflow/world-local): a session stored
// in a run, fencing between two processes, and a killed process whose session
// the queue route resumes with no caller.
//
//   node sdk/tests/test-workflow.mjs <world-root> [native|wasm]
//
// <world-root> holds node_modules/@workflow/world-local, installed at test
// time; libfx itself depends on no @workflow package.
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxAgent } from "../node.js";
import { FxFencedError, workflow, workflowQueuePrefix } from "../workflow.js";

const args = process.argv.slice(2);
const child = args[0] === "--child" ? Object.fromEntries(args.slice(1).map((value, index, all) => index % 2 === 0 ? [value.replace(/^--/, ""), all[index + 1]] : null).filter(Boolean)) : null;
const worldRoot = child ? child.world : args[0];
const backend = child ? child.backend : (args[1] || "native");
if (!worldRoot || !existsSync(join(worldRoot, "node_modules/@workflow/world-local"))) {
  throw new Error("usage: test-workflow.mjs <world-root> [native|wasm]; <world-root> must contain @workflow/world-local");
}
const { createWorld } = await import(pathToFileURL(join(worldRoot, "node_modules/@workflow/world-local/dist/index.js")).href);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) : null;
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");

// "send it" asks for one send_email call, then answers. Any other prompt is
// answered with its own text.
function framesFor(prompt) {
  const asked = prompt.some((message) => message.role === "user" && textOf(message) === "send it");
  if (asked && toolResults(prompt).length === 0) {
    return [
      { type: "tool-call", toolCallId: "call-send", toolName: "send_email", input: { to: "ops@example.com" } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
    ];
  }
  const text = textOf(prompt.filter((message) => message.role === "user").at(-1));
  return [
    { type: "text-delta", id: "answer", delta: asked ? "sent" : `answer to ${text}` },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
  ];
}

async function startGateway() {
  const requests = [];
  const sessionIds = [];
  const server = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ object: "list", data: [{ id: "workflow/model", type: "language" }] }));
        return;
      }
      const prompt = JSON.parse(body).prompt;
      requests.push(prompt);
      sessionIds.push(request.headers["x-session-id"]);
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(framesFor(prompt).map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  return { server, requests, sessionIds, port: server.address().port };
}

// The app's agent definition, the same in every process.
function defineAgent(port, onSend) {
  const send = {
    description: "Sends an email.",
    inputSchema: { type: "object" },
    replay: "never",
    writes: true,
    execute: (input) => onSend(input),
  };
  return (durable) => createFxAgent({
    backend,
    nativeAddon: addon,
    ...(wasm ? { wasm } : {}),
    fetch: (input, init) => {
      const url = new URL(String(input?.url ?? input));
      return url.hostname === "ai-gateway.vercel.sh" ? fetch(`http://127.0.0.1:${port}${url.pathname}`, init) : fetch(input, init);
    },
    apiKey: "workflow-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "workflow/model",
    tools: { send_email: send },
    ...durable,
  });
}

// world-local's queue teardown calls undici's Agent.close(), which Bun's
// built-in undici lacks. Only that known failure is skipped, and only on Bun.
async function closeWorld(world) {
  try {
    await world.close?.();
  } catch (error) {
    if (!(process.versions.bun && error instanceof TypeError && error.message.includes("httpAgent?.close"))) throw error;
  }
}

async function run(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

// Child: run "send it" and stop inside send_email after its effect, the way
// a process dies mid-turn. The parent kills it there.
if (child) {
  const world = createWorld({ dataDir: child.data, recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(Number(child.port), async () => {
    appendFileSync(child.effects, "send_email\n");
    process.stdout.write("effect\n");
    await new Promise(() => {});
  });
  const agent = await createAgent(workflow({ world, sessionId: child.session }));
  await run(agent, "send it");
  throw new Error("the child should have been killed inside send_email");
}

const gateway = await startGateway();
const cases = [];
const test = (name, body) => cases.push({ name, body });

test("a session stored in a World restores in a new agent", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(gateway.port, () => "sent");
  const first = workflow({ world });
  gateway.sessionIds.length = 0;
  const agent = await createAgent(first);
  assert.equal((await run(agent, "remember plums")).stopReason, "end_turn");
  await agent.close();
  assert.match(first.sessionId, /^wrun_/);

  const again = await createAgent(workflow({ world, sessionId: first.sessionId }));
  gateway.requests.length = 0;
  await run(again, "what did I say");
  await again.close();
  const users = gateway.requests[0].filter((message) => message.role === "user").map(textOf);
  assert.ok(users.includes("remember plums"), "the restored session holds the earlier turn");
  // The run id is the session id in every gateway request, before and after the restore.
  assert.ok(gateway.sessionIds.length >= 2 && gateway.sessionIds.every((id) => id === first.sessionId), JSON.stringify(gateway.sessionIds));
  await closeWorld(world);
});

test("a second process on the session fences the first", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  const createAgent = defineAgent(gateway.port, () => "sent");
  const session = workflow({ world });
  // turn.result does not wait for the turn's last appends, so the takeover
  // below waits for them itself.
  const appends = new Set();
  const append = session.journal.append;
  session.journal.append = (batch) => {
    const written = append(batch);
    appends.add(written);
    return written;
  };
  const first = await createAgent(session);
  await run(first, "one");
  await Promise.all([...appends]);

  const second = await createAgent(workflow({ world, sessionId: session.sessionId }));
  await run(second, "two");
  await second.close();
  const fenced = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause instanceof FxFencedError;
  await assert.rejects(run(first, "three"), fenced);
  // The failure was reported once, so close() has nothing left to report.
  await first.close();

  const { events } = await workflow({ world, sessionId: session.sessionId }).journal.load();
  const commits = events.filter((event) => event.type === "turn_committed").map((event) => event.data.user.text);
  assert.deepEqual(commits, ["one", "two"]);
  await closeWorld(world);
});

test("a killed process's session resumes from the queue with no caller", async () => {
  const data = mkdtempSync(join(tmpdir(), "libfx-world-"));
  const effects = join(data, "effects.log");
  const setup = createWorld({ dataDir: data, recoverActiveRuns: false });
  await setup.start?.();
  const created = workflow({ world: setup });
  await created.journal.load();
  await closeWorld(setup);

  const execArgs = backend === "wasm" && !process.versions.bun ? ["--experimental-wasm-jspi"] : [];
  const worker = spawn(process.execPath, [...execArgs, fileURLToPath(import.meta.url), "--child",
    "--world", worldRoot, "--backend", backend, "--data", data, "--session", created.sessionId,
    "--port", String(gateway.port), "--effects", effects], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  worker.stderr.on("data", (chunk) => { stderr += chunk; });
  await new Promise((resolveEffect, rejectEffect) => {
    worker.stdout.on("data", (chunk) => { if (String(chunk).includes("effect")) resolveEffect(); });
    worker.on("exit", (code) => rejectEffect(new Error(`worker exited (${code}) before the effect: ${stderr}`)));
  });
  worker.kill("SIGKILL");
  await new Promise((resolveExit) => worker.once("close", resolveExit));
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");

  // A new process: starting the World re-enqueues the session's run, and the
  // queue delivers it to the route.
  // The first delivery comes right after the kill, before the turn has been
  // silent for wakeAfterSeconds, so the route checks again later.
  let sends = 0;
  let agents = 0;
  const deliveries = [];
  const world = createWorld({ dataDir: data, recoverActiveRuns: true });
  const build = defineAgent(gateway.port, () => { sends += 1; return "sent"; });
  const durable = workflow({ world, wakeAfterSeconds: 1, createAgent: (options) => { agents += 1; return build(options); } });
  gateway.requests.length = 0;
  const resumed = new Promise((resolveResumed, rejectResumed) => {
    world.registerHandler(workflowQueuePrefix, async (request) => {
      try {
        const before = agents;
        const response = await durable.handler(request);
        deliveries.push({ status: response.status, resumed: agents > before });
        if (agents > before) resolveResumed();
        return response;
      } catch (error) {
        rejectResumed(error);
        throw error;
      }
    });
  });
  await world.start();
  await resumed;
  await closeWorld(world);
  assert.equal(agents, 1);
  assert.deepEqual(deliveries.map((delivery) => delivery.resumed), [false, true]);
  assert.ok(deliveries.every((delivery) => delivery.status === 204));

  assert.equal(sends, 0, "send_email did not run again");
  assert.equal(readFileSync(effects, "utf8"), "send_email\n");
  const body = JSON.stringify(gateway.requests[0]);
  assert.ok(body.includes("Resuming from unexpected session interruption."), "the model is told");
  assert.match(JSON.stringify(toolResults(gateway.requests[0])), /may have partly run/);

  // The session's journal now ends with the resumed turn committed.
  const reader = createWorld({ dataDir: data, recoverActiveRuns: false });
  const { events } = await workflow({ world: reader, sessionId: created.sessionId }).journal.load();
  const last = events.at(-1);
  assert.equal(last.type, "turn_committed");
  assert.equal(last.data.kind, "assistant");
  assert.equal(last.data.user.text, "send it");
  await closeWorld(reader);
});

test("a wake while the owner is still running does not take the session over", async () => {
  const world = createWorld({ dataDir: mkdtempSync(join(tmpdir(), "libfx-world-")), recoverActiveRuns: false });
  await world.start?.();
  let sends = 0;
  let agents = 0;
  let deliveries = 0;
  // send_email outlasts wakeAfterSeconds; the owner's heartbeats keep the turn fresh.
  const build = defineAgent(gateway.port, async () => {
    sends += 1;
    await new Promise((resolveSend) => setTimeout(resolveSend, 2500));
    return "sent";
  });
  const route = workflow({ world, wakeAfterSeconds: 1, createAgent: (options) => { agents += 1; return build(options); } });
  world.registerHandler(workflowQueuePrefix, async (request) => {
    deliveries += 1;
    return route.handler(request);
  });
  const owner = await build(workflow({ world, wakeAfterSeconds: 1 }));
  assert.equal((await run(owner, "send it")).stopReason, "end_turn");
  await owner.close();
  // Let the last queued check arrive and find the turn closed.
  await new Promise((resolveWait) => setTimeout(resolveWait, 1500));
  await closeWorld(world);
  assert.ok(deliveries >= 2, `the queue delivered ${deliveries} wakes during the turn`);
  assert.equal(agents, 0, "no wake took the session over");
  assert.equal(sends, 1);
});

try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`workflow integration passed: ${backend}`);
} finally {
  gateway.server.closeAllConnections();
  await new Promise((resolveClose) => gateway.server.close(resolveClose));
}
