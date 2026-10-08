#!/usr/bin/env bun
// Drives real libfx, with its Zig kernel loaded through the native addon or
// WebAssembly, along paths of the TLC state graph of DurableSession.tla, and
// checks after every step that the code is in a state the model allows.
//
//   bun sdk/tests/model/drive.mjs [send|lookup] [--walks N] [--seed S] [--backend native|wasm]
//     [--durability local|vercel]
//
// With --durability vercel the agents keep the session in Vercel's World
// (see sdk/tests/vercel-storage.mjs for what it needs) instead of files.
//
// `./check.sh` model-checks the spec and writes graphs/<tool>.dot. Each walk
// starts two agents, A and B, on one local() World directory. Every model
// request and tool call waits until the driver releases it, and so does each
// worker's claim on the session, so the driver decides the interleaving: it
// performs the step the walk chose, waits for the code to settle, reads back
// each worker's position, the tool runs, and the epoch of every UI line, and
// moves to the successor state that matches. A step the model has no
// matching successor for is a conformance failure.
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../node.js";
import { local } from "../../durable/local.mjs";
import { holdWrites } from "../hold-writes.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const tool = args.find((arg) => arg === "send" || arg === "lookup") ?? "send";
const walks = Number(option("walks", 40));
const backend = option("backend", "native");
const durabilityKind = option("durability", "local");
if (durabilityKind !== "local" && durabilityKind !== "vercel") throw new Error("--durability is local or vercel");
// Vercel's World is a round trip away: settle, wait for streams, and give up
// on a step later.
const remote = durabilityKind === "vercel";
const settleMs = remote ? 1500 : 60;
const streamQuietMs = remote ? 2500 : 120;
const stepTimeoutMs = remote ? 30_000 : 5000;
const { vercelStorage } = remote ? await import("../vercel-storage.mjs") : {};
const verbose = args.includes("--verbose");
let seed = Number(option("seed", 1));
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const Workers = ["A", "B"];

// ---------------------------------------------------------------------------
// The state graph TLC wrote.

// A TLA+ value as TLC prints it: numbers, strings, booleans, records (and
// functions over names, which print as records), and sequences.
function parseValue(text) {
  let at = 0;
  const space = () => { while (/\s/.test(text[at] ?? "")) at += 1; };
  const expect = (token) => {
    space();
    if (!text.startsWith(token, at)) throw new Error(`expected ${token} at ${at} in ${text}`);
    at += token.length;
  };
  const value = () => {
    space();
    if (text.startsWith("<<", at)) {
      at += 2;
      const items = [];
      space();
      if (text.startsWith(">>", at)) { at += 2; return items; }
      for (;;) {
        items.push(value());
        space();
        if (text[at] === ",") { at += 1; continue; }
        expect(">>");
        return items;
      }
    }
    if (text[at] === "[") {
      at += 1;
      const record = {};
      for (;;) {
        space();
        const key = /^[A-Za-z_][A-Za-z0-9_]*/.exec(text.slice(at))?.[0];
        if (!key) throw new Error(`expected a field at ${at} in ${text}`);
        at += key.length;
        expect("|->");
        record[key] = value();
        space();
        if (text[at] === ",") { at += 1; continue; }
        expect("]");
        return record;
      }
    }
    if (text[at] === "\"") {
      const end = text.indexOf("\"", at + 1);
      const string = text.slice(at + 1, end);
      at = end + 1;
      return string;
    }
    for (const [token, result] of [["TRUE", true], ["FALSE", false]]) {
      if (text.startsWith(token, at)) { at += token.length; return result; }
    }
    const number = /^-?\d+/.exec(text.slice(at))?.[0];
    if (number) { at += number.length; return Number(number); }
    throw new Error(`cannot read a value at ${at} in ${text}`);
  };
  const result = value();
  space();
  if (at !== text.length) throw new Error(`trailing text at ${at} in ${text}`);
  return result;
}

async function loadGraph(path) {
  const dot = await readFile(path, "utf8").catch(() => {
    throw new Error(`${path} is missing; run sdk/tests/model/check.sh first`);
  });
  const states = new Map();
  const next = new Map();
  let init = null;
  const unescape = (label) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to] = edge;
      if (!next.has(from)) next.set(from, new Set());
      next.get(from).add(to);
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
    if (node) {
      const [, id, label] = node;
      const state = {};
      // One entry per variable; TLC wraps a long value over several lines.
      for (const entry of unescape(label).split(/\n(?=\/\\ )/)) {
        const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
        if (match) state[match[1]] = parseValue(match[2].trim());
      }
      states.set(id, state);
      if (state.act?.name === "Init") init = id;
    }
  }
  assert.ok(init, "the graph has an initial state");
  return { states, next, init };
}

// The epochs of the lines every reader shows, by the spec's ShownAt: each
// line no earlier line outranks.
const shownEpochs = (lines) => {
  let high = 0;
  const shown = [];
  for (const line of lines) {
    if (line.e < high) continue;
    high = line.e;
    shown.push(line.e);
  }
  return shown;
};
// What the driver compares: everything the code shows from outside.
const view = (state) => JSON.stringify({ pc: state.pc, frozen: state.frozen, runs: state.runs, ui: shownEpochs(state.ui) });
const sameAct = (a, b) => a.name === b.name && a.w === b.w;

// ---------------------------------------------------------------------------
// The code under test: two agents on one World, with every model request and
// tool call held until the driver lets it go.

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const sse = (frames) => new Response(
  [...frames, "[DONE]"].map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const modeledLines = new Set(["turn_start", "turn_resume", "tool_start", "tool_end", "text_delta", "turn_yield", "turn_end"]);
const liveHolders = globalThis[Symbol.for("libfx.liveHolders")];
const durableInternals = Symbol.for("libfx.durableInternals");
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) return false;
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
  return true;
};
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));

// The queue as the driver runs it: a message the code asks to have delivered
// again later, as a backstop, is not, so nothing runs that the driver did not
// start. One handed back at a deadline still comes back at once.
function withoutBackstops(durability) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...args) => {
            const result = await handler(...args);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-model-"));
  const requests = [];
  const calls = [];
  const fenced = { A: 0, B: 0 };
  const holders = { A: [], B: [] };
  const claimed = { A: null, B: null };
  const frozen = { A: false, B: false };
  // Each worker's claims on the session: a holder's first lease waits until
  // the driver lets it land.
  const writes = {};
  let runs = 0;
  let sessionId = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  const agents = {};
  for (const w of Workers) {
    const claims = new Set();
    const [durability, held] = holdWrites(withoutBackstops(remote ? vercelStorage({ dir }) : local({ dir })), (entry) => {
      if (entry.k !== "lease" || claims.has(entry.holder)) return false;
      claims.add(entry.holder);
      return true;
    });
    writes[w] = held;
    agents[w] = createFxAgent({
      backend,
      nativeAddon: addon,
      ...(wasm ? { wasm } : {}),
      apiKey: "model-key",
      model: "model/test",
      async fetch(input, init) {
        // The WebAssembly host passes a Request, the native one a URL and init.
        const request = input instanceof Request ? input : new Request(input, init);
        if (request.method === "GET") return Response.json({ object: "list", data: [{ id: "model/test", type: "language" }] });
        const prompt = JSON.parse(await request.text()).prompt;
        const signal = init?.signal ?? request.signal;
        return new Promise((resolveResponse, rejectResponse) => {
          const entry = { w, kind: toolResults(prompt).length > 0 ? "model2" : "model1", answer: (frames) => { remove(requests, entry); resolveResponse(sse(frames)); } };
          requests.push(entry);
          signal?.addEventListener("abort", () => { remove(requests, entry); rejectResponse(signal.reason ?? new Error("aborted")); }, { once: true });
        });
      },
      tools: [{
        name: tool,
        description: tool === "send" ? "Sends an invoice" : "Looks up a key",
        ...(tool === "lookup" ? { idempotent: true } : {}),
        inputSchema: { type: "object", properties: { key: { type: "string" } } },
        execute: (input, { signal }) => {
          runs += 1;
          return new Promise((resolveCall, rejectCall) => {
            const entry = { w, end: () => { remove(calls, entry); resolveCall(`value of ${input.key}`); } };
            calls.push(entry);
            signal?.addEventListener("abort", () => { remove(calls, entry); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
          });
        },
      }],
      durability,
      onEvent: (event) => { if (event.type === "session.fenced") fenced[w] += 1; },
    });
  }

  async function streamLines(cursor = 0) {
    if (!sessionId) return [];
    const reader = agents.A.session(sessionId).stream(cursor).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), streamQuietMs); });
      const { value, done } = await Promise.race([reader.read(), quiet]);
      clearTimeout(timer);
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
    await reader.cancel().catch(() => {});
    return lines;
  }

  // Where each worker is, by what it waits on. A worker whose claim is held
  // may already wait on its first model request.
  const position = (w, lines) => {
    if (writes[w].held.length > 0) return "early";
    if (claimed[w] === null) return "none";
    if (fenced[w] > claimed[w].fenced) return "stopped";
    if (lines.some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch)) return "done";
    const request = requests.find((entry) => entry.w === w);
    if (request) return request.kind;
    if (calls.some((entry) => entry.w === w)) return "tool";
    return "busy";
  };
  const waiting = (w) => requests.some((entry) => entry.w === w) || calls.some((entry) => entry.w === w);
  const newHolders = (before) => [...liveHolders].filter((holder) => !before.has(holder));

  async function observe() {
    const lines = await streamLines();
    // A reader that reconnects from any cursor sees the same lines after it.
    if (lines.length > 0) {
      const cursor = lines[Math.floor(random() * lines.length)].cursor;
      const again = await streamLines(cursor);
      assert.deepEqual(again, lines.filter((line) => line.cursor > cursor), `reconnecting from cursor ${cursor} shows the same lines`);
    }
    return {
      pc: Object.fromEntries(Workers.map((w) => [w, position(w, lines)])),
      frozen: { ...frozen },
      runs,
      ui: lines.filter((line) => modeledLines.has(line.type)).map((line) => line.epoch ?? 0),
    };
  }

  // One step of the model, done to the code.
  async function perform({ name, w }, expectedEpoch) {
    const stopped = () => claimed[w] !== null && fenced[w] > claimed[w].fenced;
    if (name === "Start") {
      // w receives work for the session; its claim waits for the driver.
      const before = new Set(liveHolders);
      if (!sessionId) {
        const turn = agents[w].session().prompt(`use ${tool}`, { messageId: "turn-1" });
        void turn.result.catch(() => {});
        sessionId = (await turn.accepted).sessionId;
      } else {
        void agents[w].session(sessionId).resume().result.catch(() => {});
      }
      await until(() => writes[w].held.length > 0);
      holders[w] = newHolders(before);
    } else if (name === "Claim") {
      // w's claim lands, and the log says whether it counted. One that did
      // goes on with the turn; a refused one leaves w to read the log again,
      // and to claim again or let the message go.
      const holder = writes[w].held.at(-1).holder;
      const before = new Set(liveHolders);
      await writes[w].releaseHeld();
      if ((await agents[w][durableInternals].lastLease(sessionId))?.holder === holder) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        await until(() => waiting(w) || stopped());
      } else {
        await until(() => writes[w].held.length > 0 || agents[w][durableInternals].liveWorkers() === 0);
        holders[w] = newHolders(before);
        claimed[w] = null;
      }
    } else if (name === "Model1" || name === "Model2") {
      const request = requests.find((entry) => entry.w === w);
      assert.ok(request, `${w} has a model request to answer`);
      request.answer(name === "Model1"
        ? [{ type: "tool-call", toolCallId: "call-1", toolName: tool, input: { key: "alpha" } }, finish("tool-calls")]
        : [{ type: "text-delta", id: "answer", delta: "done" }, finish("stop")]);
      if (name === "Model1") await until(() => calls.some((entry) => entry.w === w) || stopped());
      else await until(async () => stopped() || (await streamLines()).some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch));
    } else if (name === "ToolEnd") {
      const call = calls.find((entry) => entry.w === w);
      assert.ok(call, `${w} has a tool call to end`);
      call.end();
      await until(() => requests.some((entry) => entry.w === w && entry.kind === "model2") || stopped());
    } else if (name === "Freeze") {
      // The platform gives up on w: its lease no longer counts as alive.
      for (const holder of holders[w]) liveHolders.delete(holder);
      frozen[w] = true;
    } else if (name === "Wake") {
      frozen[w] = false;
    } else if (name === "Deadline") {
      // w's timer fires: it stops, and the same message comes back to it.
      const before = new Set(liveHolders);
      const fencedBefore = fenced[w];
      agents[w][durableInternals].stopAtDeadline(sessionId);
      const reclaimed = () => [...liveHolders].some((holder) => !before.has(holder));
      // The same message comes back to w, and its claim lands at once.
      await until(() => {
        if (writes[w].held.length > 0) writes[w].releaseHeld();
        return (reclaimed() && waiting(w) && writes[w].held.length === 0) || fenced[w] > fencedBefore;
      });
      if (reclaimed()) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        holders[w] = [...liveHolders].filter((holder) => !before.has(holder));
      }
    }
    // Let background writes land before the code is read back.
    await sleep(settleMs);
  }

  async function close() {
    for (const w of Workers) writes[w].release();
    for (const entry of [...requests]) entry.answer([{ type: "error", errorText: "walk over" }]);
    for (const entry of [...calls]) entry.end();
    await Promise.race([Promise.all(Workers.map((w) => agents[w].close().catch(() => {}))), sleep(3000)]);
    await rm(dir, { recursive: true, force: true });
  }

  return { perform, observe, close };
}

// ---------------------------------------------------------------------------
// Walks.

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "graphs", `${tool}.dot`));
const covered = new Set();
const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + targets.size, 0);
let steps = 0;

const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const actOf = (id) => graph.states.get(id).act;

for (let walk = 1; walk <= walks; walk += 1) {
  const code = await harness();
  const path = [];
  // Every model state the code could be in, given all it has shown so far.
  let current = new Set([graph.init]);
  try {
    for (;;) {
      // The steps the driver can take. Announce follows at once in the code
      // whenever a worker claims, so the two are one step here.
      const options = [];
      for (const from of current) {
        for (const to of successors(from)) {
          const act = actOf(to);
          if (act.name === "Announce") continue;
          // local() hands a message that comes back at the deadline to the
          // same worker, so a Deadline that only releases the session is a
          // path the code cannot take.
          if (act.name === "Deadline" && graph.states.get(to).pc[act.w] === "none") continue;
          let option = options.find((item) => sameAct(item.act, act));
          if (!option) options.push(option = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) option.fresh = true;
        }
      }
      if (options.length === 0) break;
      const fresh = options.filter((option) => option.fresh);
      const pool = fresh.length > 0 ? fresh : options;
      const { act } = pool[Math.floor(random() * pool.length)];
      const expectedEpoch = act.name === "Claim" || act.name === "Deadline"
        ? Math.max(...[...current].flatMap((from) => successors(from).filter((to) => sameAct(actOf(to), act)).map((to) => graph.states.get(to).epoch[act.w])))
        : undefined;
      if (verbose) console.log(`walk ${walk}: ${act.name}(${act.w})`);
      await code.perform(act, expectedEpoch);
      const seen = JSON.stringify(await code.observe());
      if (verbose) console.log(`  shows ${seen}`);
      path.push(`${act.name}(${act.w})`);
      steps += 1;
      const next = new Set();
      const allowed = new Set();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const ends = graph.states.get(to).pc[act.w] === "announce"
            ? successors(to).filter((id) => sameAct(actOf(id), { name: "Announce", w: act.w })).map((id) => [to, id])
            : [[null, to]];
          for (const [middle, end] of ends) {
            allowed.add(view(graph.states.get(end)));
            if (view(graph.states.get(end)) !== seen) continue;
            next.add(end);
            covered.add(`${from}>${middle ?? end}`);
            if (middle) covered.add(`${middle}>${end}`);
          }
        }
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const view of allowed) console.error(`  the model allows ${view}`);
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.message}`);
    process.exitCode = 1;
  } finally {
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 25 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
if (!process.exitCode) console.log(`ok ${tool}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend})`);
// An agent a failed walk left mid-turn keeps timers alive; nothing more runs.
process.exit(process.exitCode ?? 0);
