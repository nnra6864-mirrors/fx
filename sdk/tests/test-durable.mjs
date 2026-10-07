#!/usr/bin/env node
// Durable sessions through createFxAgent: the production problems Rauch's
// durability doc lists, on memory() and local(), against a fake gateway.
//
//   node --experimental-wasm-jspi sdk/tests/test-durable.mjs [memory|local] [native|wasm]
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, memory } from "../node.js";
import { foldSessionLog } from "../durable.js";

const durabilityKind = process.argv[2] || "memory";
const engineBackend = process.argv[3] || "native";
const childMode = process.argv[4] === "--child";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = engineBackend === "wasm" ? await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) : undefined;
const { local } = durabilityKind === "memory" ? {} : await import("../durable/local.mjs");
// "vercel": Vercel's World holds the sessions; see vercel-storage.mjs.
const { vercelStorage } = durabilityKind === "vercel" ? await import("./vercel-storage.mjs") : {};
// Vercel's World is a round trip away, so its tests wait longer for a
// stream's next chunk, give a function more time, and run longer.
const remote = durabilityKind === "vercel";
const streamQuietMs = remote ? 3000 : 300;
// A remote stream's first chunk waits for its connection as well.
const streamFirstMs = remote ? 15_000 : streamQuietMs;
const timeScale = remote ? 6 : 1;
const testTimeoutMs = remote ? 120_000 : 30_000;
const durabilityAt = (dir, options = {}) => (durabilityKind === "vercel" ? vercelStorage({ dir, ...options }) : local({ dir, ...options }));
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const resumeNotice = "Resuming from unexpected session interruption.";

const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const userTexts = (prompt) => prompt.filter((message) => message.role === "user").map(textOf);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const toolCall = (id, name, input) => [{ type: "tool-call", toolCallId: id, toolName: name, input }, finish("tool-calls")];
const answer = (text) => [{ type: "text-delta", id: "answer", delta: text }, finish("stop")];

// The model, by the newest user message of the request, past any resume
// notice: "use <tool>" calls the tool once, then answers with its result;
// "loop" calls lookup three times; anything else is echoed.
function framesFor(prompt) {
  const users = userTexts(prompt).filter((text) => text !== resumeNotice);
  const text = users.at(-1) ?? "";
  const results = toolResults(prompt);
  const turnResults = results.filter((part) => String(part.toolCallId).startsWith(`call-${users.length}-`));
  if (text.startsWith("use ")) {
    const tool = text.slice(4).split(" ")[0];
    if (turnResults.length === 0) return toolCall(`call-${users.length}-0`, tool, { key: "alpha" });
    return answer(`done: ${JSON.stringify(turnResults.at(-1).output)}`);
  }
  if (text === "loop") {
    if (turnResults.length < 3) return toolCall(`call-${users.length}-${turnResults.length}`, "lookup", { key: `k${turnResults.length}` });
    return answer(`looped ${turnResults.length}`);
  }
  return answer(`echo: ${text}`);
}

const requests = [];
let inFlight = 0;
let maxInFlight = 0;
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "durable/model", type: "language" }] }));
      return;
    }
    const prompt = JSON.parse(body).prompt;
    requests.push(prompt);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    // Each answer takes a moment, so overlapping workers would overlap here.
    setTimeout(() => {
      inFlight -= 1;
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.end(framesFor(prompt).map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
    }, 15);
  });
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const { port } = server.address();
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  if (url.hostname === "ai-gateway.vercel.sh") return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  return fetch(input, init);
};

// Tools. A gate holds a call until the test opens it.
const runs = [];
const gates = new Map();
const gate = (name) => {
  let open;
  const promise = new Promise((resolveGate) => { open = resolveGate; });
  const entry = { promise, open, started: null };
  entry.started = new Promise((resolveStarted) => { entry.markStarted = resolveStarted; });
  gates.set(name, entry);
  return entry;
};
const lookup = {
  name: "lookup",
  description: "Looks up a key",
  idempotent: true,
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async ({ key }, { executionId }) => {
    runs.push(["lookup", executionId]);
    const held = gates.get("lookup");
    if (held) {
      held.markStarted();
      await held.promise;
    }
    return `value of ${key}`;
  },
};
const send = {
  name: "send",
  description: "Sends an invoice",
  inputSchema: { type: "object", properties: { key: { type: "string" } } },
  execute: async (_input, { executionId }) => {
    runs.push(["send", executionId]);
    const held = gates.get("send");
    if (held) {
      held.markStarted();
      await held.promise;
    }
    return "sent";
  },
};

const dirs = [];
async function durabilityFor(options = {}) {
  if (durabilityKind === "memory") return memory(options);
  const dir = options.dir ?? await mkdtemp(join(tmpdir(), "libfx-durable-"));
  dirs.push(dir);
  return durabilityAt(dir, options);
}
const agentOptions = (durability, extra = {}) => ({
  backend: engineBackend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "durable-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "durable/model",
  tools: [lookup, send],
  durability,
  ...extra,
});

async function collect(turn) {
  let text = "";
  const types = [];
  for await (const event of turn) {
    types.push(event.type);
    if (event.type === "text_delta") text += event.delta;
  }
  return { text, types, result: await turn.result };
}

// Up to `count` lines, or what arrives before the stream is quiet for
// `quietMs`: a session's stream follows it forever.
async function readLines(stream, count, quietMs = streamQuietMs) {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  const lines = [];
  while (lines.length < count) {
    let timer;
    const wait = lines.length === 0 && buffered === "" ? Math.max(quietMs, streamFirstMs) : quietMs;
    const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), wait); });
    const { value, done } = await Promise.race([reader.read(), quiet]);
    clearTimeout(timer);
    if (done) break;
    buffered += decoder.decode(value, { stream: true });
    for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
      lines.push(JSON.parse(buffered.slice(0, index)));
      buffered = buffered.slice(index + 1);
    }
  }
  await reader.cancel();
  return lines.slice(0, count);
}

const until = async (check, what, ms = 10_000) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) throw new Error(`timed out waiting for ${what}`);
    await new Promise((wait) => setTimeout(wait, 10));
  }
};

// A child process for the crash tests. With a tool, it starts a turn whose
// tool never finishes and prints the session id once the tool runs. With
// `accepted`, it dies the moment its prompt is accepted.
if (childMode && process.argv[6] === "accepted") {
  const agent = createFxAgent(agentOptions(durabilityAt(process.argv[5])));
  const session = agent.session();
  const { sessionId } = await session.prompt("hello").accepted;
  process.stdout.write(`${JSON.stringify({ sessionId })}\n`, () => process.kill(process.pid, "SIGKILL"));
  await new Promise(() => {});
}
if (childMode) {
  const dir = process.argv[5];
  const tool = process.argv[6];
  gate(tool);
  const agent = createFxAgent(agentOptions(durabilityAt(dir)));
  const session = agent.session();
  void session.prompt(`use ${tool}`, { messageId: "crash-turn" }).result.catch(() => {});
  await gates.get(tool).started;
  // A safe call starts before its record lands: wait for it, so the crash
  // comes after the log holds the call.
  await agent[Symbol.for("libfx.durableInternals")].settled(session.id);
  console.log(JSON.stringify({ sessionId: session.id }));
  await new Promise(() => {});
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("a prompt streams its turn, and the session replays from any cursor", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const turn = agent.prompt("hello");
  const { text, result } = await collect(turn);
  assert.equal(text, "echo: hello");
  assert.equal(result.stopReason, "end_turn");
  const accepted = await turn.accepted;
  assert.match(accepted.messageId, /^msg_/);
  assert.equal(accepted.sessionId, agent.sessionId);
  const lines = await readLines(agent.session(agent.sessionId).stream(0), 3);
  assert.deepEqual(lines.map((line) => line.type), ["turn_start", "text_delta", "turn_end"]);
  assert.equal(lines[0].sessionId, agent.sessionId, "a client learns the session from the first line");
  assert.deepEqual(lines.map((line) => line.cursor), [1, 2, 3]);
  const later = await readLines(agent.session(agent.sessionId).stream(2), 1);
  assert.equal(later[0].type, "turn_end");
  await agent.close();
});

test("each session's stream holds only its own turns", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const first = agent.session();
  const second = agent.session();
  await collect(first.prompt("first session"));
  await collect(second.prompt("second session"));
  for (const [session, input] of [[first, "first session"], [second, "second session"]]) {
    const lines = await readLines(session.stream(0), 16);
    const starts = lines.filter((line) => line.type === "turn_start");
    assert.deepEqual(starts.map((line) => line.input), [input], "a stream never shows another session's turn");
    assert.ok(starts.every((line) => line.sessionId === session.id));
  }
  await agent.close();
});

test("a retried prompt with the same messageId runs its turn once", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const session = agent.session();
  const first = await collect(session.prompt("only once", { messageId: "same-1" }));
  const before = requests.length;
  const repeat = session.prompt("only once", { messageId: "same-1" });
  const again = await repeat.result;
  const repeatedLines = await readLines(repeat.readable, 1);
  assert.equal(repeatedLines[0].type, "turn_end", "a route returning readable still sends the outcome");
  assert.equal(repeatedLines[0].repeated, true);
  assert.equal(first.result.stopReason, "end_turn");
  assert.equal(again.stopReason, "end_turn");
  assert.equal(again.repeated, true);
  assert.equal(requests.length, before, "the retry sent nothing to the model");
  await agent.close();
});

test("two servers prompting one session run its turns one at a time, in one history", async () => {
  const durability = await durabilityFor();
  const one = createFxAgent(agentOptions(durability));
  const two = createFxAgent(agentOptions(durability));
  const session = one.session();
  await session.prompt("first").result;
  maxInFlight = 0;
  const id = session.id;
  const [a, b] = await Promise.all([
    collect(one.session(id).prompt("from one")),
    collect(two.session(id).prompt("from two")),
  ]);
  assert.equal(a.result.stopReason, "end_turn");
  assert.equal(b.result.stopReason, "end_turn");
  assert.equal(maxInFlight, 1, "only one worker ran the session at a time");
  const last = requests.at(-1);
  const users = userTexts(last);
  assert.equal(users[0], "first");
  assert.ok(users.includes("from one") && users.includes("from two"), "the later turn saw the earlier one");
  await one.close();
  await two.close();
});

test("a steer reaches the running turn at its next model request", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const held = gate("lookup");
  const session = agent.session();
  const turn = session.prompt("use lookup please");
  await held.started;
  await session.steer("also mention the color blue");
  // The worker takes it from the log while the tool runs.
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  held.open();
  gates.delete("lookup");
  const { result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn");
  assert.ok(JSON.stringify(requests.at(-1)).includes("also mention the color blue"), "the next request carried the steer");
  await agent.close();
});

test("cancel stops the running turn; dropping its view does not", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  const held = gate("lookup");
  const session = agent.session();
  const dropped = session.prompt("use lookup for dropping");
  for await (const _event of dropped) break;
  await held.started;
  const turn = session.prompt("after the dropped one");
  await new Promise((wait) => setTimeout(wait, 30));
  assert.equal(gates.get("lookup"), held, "the dropped turn still runs");
  await session.cancel();
  await new Promise((wait) => setTimeout(wait, durabilityKind === "memory" ? 50 : 600));
  held.open();
  gates.delete("lookup");
  assert.equal((await dropped.result).stopReason, "cancelled");
  assert.equal((await turn.result).stopReason, "end_turn");
  await agent.close();
});

test("every turn's end saves a checkpoint, and the next turn starts from it", async () => {
  const saves = [];
  const opens = [];
  const agent = createFxAgent(agentOptions(await durabilityFor(), {
    onEvent: (event) => {
      if (event.type === "checkpoint.save") saves.push(event);
      else if (event.type === "journal.open") opens.push(event);
    },
  }));
  const session = agent.session();
  for (const text of ["use lookup", "hello again"]) assert.equal((await collect(session.prompt(text))).result.stopReason, "end_turn");
  await agent.close();
  assert.equal(saves.length, 2, JSON.stringify(saves));
  const later = opens.filter((open) => open.turns > 0);
  assert.ok(later.length >= 1 && later.every((open) => open.checkpoint && open.events === 0), JSON.stringify(opens));
});

test("a checkpoint where a turn yielded keeps the turn open, and its steers stay its own", () => {
  const log = [
    { cursor: "1", entry: { k: "lease", a: null, holder: "w1", epoch: 1, expiresAt: null } },
    { cursor: "2", entry: { k: "input", key: "prompt:p1", type: "prompt", messageId: "p1", input: "loop" } },
    { cursor: "3", entry: { k: "record", a: "1", key: "r1", data: "AA==", marks: [{ start: "p1" }] } },
    { cursor: "4", entry: { k: "input", key: "steer:s1", type: "steer", messageId: "s1", input: "also this" } },
    { cursor: "5", entry: { k: "record", a: "3", key: "r2", data: "AA==", marks: [{ yield: true }] } },
  ];
  const before = foldSessionLog(log);
  assert.equal(before.openTurn.id, "p1");
  assert.equal(before.yielded, true);
  assert.deepEqual(before.steers.map((input) => input.messageId), ["s1"]);
  // The checkpoint a worker saves at that yield.
  const checkpoint = {
    k: "checkpoint",
    through: "5",
    data: "AA==",
    pending: before.unconsumed.filter((input) => input.cursor <= 5),
    recent: before.recent,
    lastTurnId: before.lastTurnId,
    openTurn: before.openTurn,
    yielded: before.yielded,
    lease: before.lastLease,
  };
  const after = foldSessionLog([{ cursor: "6", entry: checkpoint }]);
  assert.deepEqual(after.openTurn, before.openTurn);
  assert.equal(after.yielded, true);
  assert.deepEqual(after.steers.map((input) => input.messageId), ["s1"], "the open turn's steer stays its steer");
  assert.deepEqual(after.pending, [], "no input becomes a new turn");
  assert.equal(after.lastEpoch, 1);
});

test("a turn longer than a function's time limit continues in the next delivery", async () => {
  const saves = [];
  const opens = [];
  const errors = [];
  const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1, reserveMs: 0 }), {
    onEvent: (event) => {
      if (event.type === "checkpoint.save") saves.push(event);
      else if (event.type === "checkpoint.error") errors.push(event);
      else if (event.type === "journal.open") opens.push(event);
    },
  }));
  const before = requests.length;
  const runsBefore = runs.length;
  const session = agent.session();
  const turn = session.prompt("loop");
  const { text, result } = await collect(turn);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "looped 3");
  const sent = requests.slice(before);
  assert.equal(sent.length, 4, "each model step ran once");
  assert.ok(sent.every((prompt) => !JSON.stringify(prompt).includes(resumeNotice)), "a yield is not an interruption");
  assert.equal(runs.length - runsBefore, 3, "each tool call ran once");
  // Every delivery after the first model step stopped and handed on.
  const lines = await readLines(session.stream(0), 32);
  assert.equal(lines.filter((line) => line.type === "turn_yield").length, 3);
  assert.equal(lines.filter((line) => line.type === "turn_resume").length, 3);
  // A checkpoint at each yield and at the turn's end, and each delivery
  // after a yield loaded its checkpoint with no record after it.
  assert.deepEqual(errors, []);
  assert.equal(saves.length, 4, JSON.stringify(saves));
  const resumed = opens.filter((open) => open.resumable);
  assert.equal(resumed.length, 3);
  assert.ok(resumed.every((open) => open.checkpoint && open.events === 0), JSON.stringify(resumed));
  await agent.close();
});

for (const tool of ["lookup", "send"]) {
  test(`a ${tool} call still running near the deadline is cut off, and the next delivery continues the turn`, async () => {
    const deadlines = [];
    const agent = createFxAgent(agentOptions(await durabilityFor({ maxDurationMs: 1500 * timeScale, reserveMs: 1000 * timeScale }), {
      onEvent: (event) => { if (event.type === "session.deadline") deadlines.push(event); },
    }));
    const held = gate(tool);
    const before = runs.filter(([name]) => name === tool).length;
    const turn = agent.prompt(`use ${tool}`);
    await held.started;
    // The call never returns on its own; a rerun goes through at once.
    gates.delete(tool);
    const { result } = await collect(turn);
    assert.equal(result.stopReason, "end_turn");
    assert.equal(deadlines.length, 1, "the worker stopped itself once, before its deadline");
    const ran = runs.filter(([name]) => name === tool).length - before;
    if (tool === "lookup") assert.equal(ran, 2, "the cut-off call ran again in the next delivery");
    else {
      assert.equal(ran, 1, "a call with effects never runs twice on its own");
      assert.ok(JSON.stringify(requests.at(-1)).includes("may have partly run"), "the model hears the call may have run");
    }
    const lines = await readLines(agent.session(agent.sessionId).stream(0), 32);
    assert.equal(lines.filter((line) => line.type === "turn_yield").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_resume").length, 1);
    assert.equal(lines.filter((line) => line.type === "turn_end").length, 1);
    await agent.close();
  });
}

test("a worker that froze is replaced, and its next write is refused", async () => {
  const durability = await durabilityFor();
  const slow = createFxAgent(agentOptions(durability));
  const held = gate("lookup");
  const session = slow.session();
  const turn = session.prompt("use lookup while frozen", { messageId: "frozen-turn" });
  await held.started;
  // The platform gives up on the frozen worker: its lease no longer stands.
  const holders = globalThis[Symbol.for("libfx.liveHolders")];
  const frozen = [...holders];
  for (const holder of frozen) holders.delete(holder);
  gates.delete("lookup");
  const fresh = createFxAgent(agentOptions(durability));
  const next = fresh.session(session.id).prompt("after the takeover");
  assert.equal((await next.result).stopReason, "end_turn");
  // The open turn was continued by the new worker: lookup is idempotent, so
  // it ran again there.
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  // Waking, the frozen worker's next write is refused. A model request may
  // overlap that write, but no tool runs and the session hears nothing.
  const runsBefore = runs.length;
  held.open();
  await new Promise((wait) => setTimeout(wait, 300));
  assert.equal(runs.length, runsBefore, "the frozen worker ran no tool after waking");
  const lines = await readLines(fresh.session(session.id).stream(0), 64).catch(() => []);
  const ends = lines.filter((line) => line.type === "turn_end" && line.messageId === "frozen-turn");
  assert.equal(ends.length, 1, "the turn ended once");
  // Its late lines rank below its successor's and stay hidden, and a reader
  // that reconnects mid-stream sees the same lines.
  const epochs = lines.map((line) => line.epoch).filter(Number.isSafeInteger);
  assert.deepEqual(epochs, [...epochs].sort((a, b) => a - b), "no shown line comes from a replaced worker after its successor's");
  const middle = lines[Math.floor(lines.length / 2)].cursor;
  assert.deepEqual(await readLines(fresh.session(session.id).stream(middle), 64), lines.filter((line) => line.cursor > middle), "a reconnect shows the same lines");
  // A later turn, after the session was released, claims a higher epoch, so
  // its lines still show after the takeover's.
  const later = fresh.session(session.id).prompt("a later turn", { messageId: "later-turn" });
  assert.equal((await later.result).stopReason, "end_turn");
  const shown = await readLines(fresh.session(session.id).stream(0), 96);
  const end = shown.find((line) => line.type === "turn_end" && line.messageId === "later-turn");
  assert.ok(end, "the later turn's lines show");
  assert.ok(end.epoch > Math.max(...epochs), "the later turn's epoch outranks every earlier line");
  await slow.close();
  await fresh.close();
});

if (durabilityKind !== "memory") {
  for (const tool of ["lookup", "send"]) {
    test(`a crash during ${tool} ${tool === "send" ? "never sends twice, and the turn goes on" : "reruns the idempotent call"}`, async () => {
      const dir = await mkdtemp(join(tmpdir(), "libfx-durable-crash-"));
      dirs.push(dir);
      const child = spawn(process.execPath, [
        ...process.execArgv,
        fileURLToPath(import.meta.url),
        durabilityKind,
        engineBackend,
        "--child",
        dir,
        tool,
      ], { stdio: ["ignore", "pipe", "inherit"], env: { ...process.env } });
      let output = "";
      child.stdout.on("data", (chunk) => { output += chunk; });
      await until(() => output.includes("\n"), "the child to start its tool", 30_000);
      const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
      child.kill("SIGKILL");
      await new Promise((exited) => child.once("exit", exited));
      const runsBefore = runs.filter(([name]) => name === tool).length;
      const agent = createFxAgent(agentOptions(durabilityAt(dir)));
      const session = agent.session(sessionId);
      const resumed = await session.resume().result;
      assert.equal(resumed.stopReason, "end_turn");
      const reran = runs.filter(([name]) => name === tool).length - runsBefore;
      if (tool === "send") {
        assert.equal(reran, 0, "a call with effects never runs twice on its own");
        // The turn went on at once, and the model was told the call may have
        // partly run.
        assert.ok(JSON.stringify(requests.at(-1)).includes("may have partly run"), "the model hears the call may have run");
      } else {
        // The last request shows how the resumed turn saw the call, if not.
        assert.equal(reran, 1, `the idempotent call ran again; the model last saw ${JSON.stringify(requests.at(-1)).slice(-600)}`);
      }
      await agent.close();
    });
  }
}

if (durabilityKind !== "memory") {
  test("a prompt accepted just before a crash still runs", async () => {
    const dir = await mkdtemp(join(tmpdir(), "libfx-durable-accepted-"));
    dirs.push(dir);
    const child = spawn(process.execPath, [...process.execArgv, fileURLToPath(import.meta.url), durabilityKind, engineBackend, "--child", dir, "accepted"], {
      stdio: ["ignore", "pipe", "inherit"], env: { ...process.env },
    });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    await new Promise((exited) => child.once("exit", exited));
    const { sessionId } = JSON.parse(output.trim().split("\n")[0]);
    const agent = createFxAgent(agentOptions(durabilityAt(dir)));
    const { text, result } = await collect(agent.session(sessionId).resume());
    assert.equal(result.stopReason, "end_turn", "the accepted prompt was in the log");
    assert.equal(text, "echo: hello");
    await agent.close();
  });
}

test("an option the backend rejects fails the first turn once", async () => {
  const events = [];
  const agent = createFxAgent(agentOptions(await durabilityFor(), {
    model: { id: "durable/model", effort: "high" },
    onEvent: (event) => { if (event.type === "session.error") events.push(event); },
  }));
  const sent = requests.length;
  const result = await agent.prompt("hello").result;
  assert.equal(result.stopReason, "error");
  assert.equal(result.error?.code, "LIBFX_MODEL_UNSUPPORTED_EFFORT");
  assert.equal(events.length, 1);
  assert.equal(requests.length, sent, "no model request was made");
  await agent.close();
});

test("a checkpoint names the libfx, tools and model that saved it, and a resume with others hears so", async () => {
  const durability = await durabilityFor();
  const mismatches = (list) => (event) => { if (event.type === "checkpoint.mismatch") list.push(event); };
  const first = createFxAgent(agentOptions(durability));
  const session = first.session();
  assert.equal((await session.prompt("hello").result).stopReason, "end_turn");
  await first.close();

  const same = [];
  const again = createFxAgent(agentOptions(durability, { onEvent: mismatches(same) }));
  assert.equal((await again.session(session.id).prompt("same tools").result).stopReason, "end_turn");
  await again.close();
  assert.deepEqual(same, []);

  const changed = [];
  const other = createFxAgent(agentOptions(durability, { tools: [lookup], model: "durable/other", onEvent: mismatches(changed) }));
  assert.equal((await other.session(session.id).prompt("fewer tools").result).stopReason, "end_turn");
  await other.close();
  assert.equal(changed.length, 1, JSON.stringify(changed));
  assert.equal(changed[0].sessionId, session.id);
  assert.deepEqual(changed[0].changed, ["toolSchemaHash", "model"]);
  assert.equal(changed[0].saved.model, "durable/model");
  assert.equal(changed[0].current.model, "durable/other");
  assert.equal(changed[0].saved.libfxVersion, changed[0].current.libfxVersion);

  // A checkpoint carried to a new agent reports the same way.
  const source = createFxAgent(agentOptions(await durabilityFor()));
  await source.prompt("carry this").result;
  const checkpoint = await source.checkpoint();
  await source.close();
  const carried = [];
  const restored = createFxAgent(agentOptions(await durabilityFor(), { checkpoint, model: "durable/other", onEvent: mismatches(carried) }));
  assert.equal((await restored.prompt("still here").result).stopReason, "end_turn");
  await restored.close();
  assert.deepEqual(carried.map((event) => event.changed), [["model"]]);
});

test("a checkpoint restores the conversation in a new agent", async () => {
  const agent = createFxAgent(agentOptions(await durabilityFor()));
  await agent.prompt("remember the word kiwi").result;
  const checkpoint = await agent.checkpoint();
  assert.ok(checkpoint instanceof Uint8Array && checkpoint.byteLength > 0);
  await agent.close();
  const restored = createFxAgent(agentOptions(await durabilityFor(), { checkpoint }));
  assert.equal((await restored.prompt("what was the word").result).stopReason, "end_turn");
  assert.deepEqual(userTexts(requests.at(-1)), ["remember the word kiwi", "what was the word"]);
  await restored.close();
});

// LIBFX_TEST_ONLY runs only the tests whose names contain it.
const only = process.env.LIBFX_TEST_ONLY;
const selected = only ? tests.filter(([name]) => name.includes(only)) : tests;
let failed = 0;
for (const [name, fn] of selected) {
  const started = performance.now();
  try {
    let timer;
    await Promise.race([
      fn(),
      new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error(`timed out after ${testTimeoutMs / 1000}s`)), testTimeoutMs); }),
    ]).finally(() => clearTimeout(timer));
    console.log(`ok ${name} (${(performance.now() - started).toFixed(0)}ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n  ${error?.stack ?? error}`);
  }
}
server.close();
for (const dir of dirs) await rm(dir, { recursive: true, force: true }).catch(() => {});
console.log(`${selected.length - failed}/${selected.length} durable tests passed (${durabilityKind}, ${engineBackend})`);
process.exit(failed ? 1 : 0);
