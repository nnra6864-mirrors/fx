#!/usr/bin/env node
// Crash matrix: kill a libfx process at every step of a turn and check what
// the next process does.
//
// For each backend and workload, a worker child runs a committed setup turn,
// saves a checkpoint, then runs the crash turn one step at a time: it prints
// each step (prompt sent, each turn event, before and after each tool's side
// effect) and waits for an ack on stdin. The parent kills it with SIGKILL at
// step k instead of acking, then starts a restorer child. In "today" mode
// the restorer does what a host can do without a journal: restore the last
// checkpoint and send the stored prompt again. Side effects are counted from
// a file, and each cell is checked by durable.mjs checkCrashCell. Failures
// in "today" mode are recorded, not fatal, unless --require-clean is set.
//
// In "journal" mode the worker keeps a libfx journal in a JSONL file, with a
// step before and after each append lands, and saves no checkpoint. The
// restorer opens the session from that file alone. It calls `resume()` when
// the journal holds the crashed turn open, does nothing when the turn was
// committed, and sends the prompt again only when no trace of the turn
// reached the journal. Then it reopens the file once more. Two more
// invariants apply: JournalFolds (every reopen succeeds) and
// NeverStartsWithoutDurableIntent (checked as each never call starts).
//
// "world" mode is journal mode with the session in a world-local World
// through libfx/workflow (--world-root holds @workflow/world-local). The
// restorer delivers the session's queue message to `handler`, which resumes
// an open turn with no caller, and then opens the session itself.
//
// --race (journal or world mode) holds the worker at step k instead of
// killing it, runs the restorer while it waits, then releases it: a second
// process takes the session over while the first is still alive. Two more
// invariants apply: FencedNeverWrites (the released worker leaves the
// session as the restorer left it) and NeverRunsTwice over both processes.
//
// --inputs (journal or world mode) steers the crash turn and queues a
// follow-up when its first tool runs, each acknowledgement a step of its
// own. AckedAreDurable: an acknowledged steer or follow-up reaches the model
// after the restore; PlacedOnce: neither reaches it twice.
//
// --snapshots (journal mode) runs 66 setup turns so libfx snapshots the
// session, which the file journal stores beside the events (a temp file and
// a rename, with a step on each side) when it moves forward; loads return
// the snapshot and the events after it. Every invariant above must still
// hold, and three more apply: SnapshotNotAhead (no snapshot covers an event
// the journal has not stored), SnapshotMatchesPrefix (the session restored
// from the final snapshot and its tail sends the same request as the one
// restored from every event), and, with --race, SnapshotsMoveForward (a
// snapshot the released worker stores replaces only an older one). With
// snapshots, FencedNeverWrites compares the events alone: a late snapshot
// still summarizes exactly the events it covers.
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxAgent, FxFencedError } from "../../sdk/node.js";
import { workflow, workflowQueuePrefix } from "../../sdk/workflow.js";
import { checkCrashCell, durableTools, durableWorkloads, promptDirectives, toolResultIds } from "./durable.mjs";
import { agentOptions, hostTools, listOption, parseArgs, scriptedFetch } from "./durable-host.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const options = parseArgs(process.argv.slice(2), {
  child: "",
  backend: "native",
  backends: "native,wasm",
  workload: "",
  workloads: "no-tool,one-safe,one-never,list-then-read,write-then-read",
  dir: "",
  mode: "today",
  "world-root": "/tmp/libfx-world",
  race: false,
  inputs: false,
  snapshots: false,
  "require-clean": false,
  "timeout-ms": "20000",
});
if (!["today", "journal", "world"].includes(options.mode)) throw new Error("--mode must be today, journal or world");
const worldMode = options.mode === "world";
const journaled = options.mode !== "today";
if (options.race && !journaled) throw new Error("--race needs --mode journal or world");
if (options.inputs && !journaled) throw new Error("--inputs needs --mode journal or world");
if (options.snapshots && options.mode !== "journal") throw new Error("--snapshots needs --mode journal");
// Snapshots come every 100 events at a commit: 66 setup turns end at seq
// 199, so the crash turn's commit takes the second one while stepping.
const setupTurns = options.snapshots ? 66 : 1;
const steerText = "steer=keep";
const followUpText = "workload=no-tool follow";

// How often the steer and the follow-up reached the model in `prompt`.
function inputCounts(prompt) {
  const users = prompt.filter((message) => message.role === "user").map(textOf);
  return {
    steers: users.filter((text) => text.includes(steerText)).length,
    followUps: users.filter((text) => text.includes(followUpText)).length,
  };
}

// Runs every turn `resume()` hands back: the open turn, then held follow-ups.
async function resumeAll(agent) {
  let first = null;
  for (let turn = agent.resume(); turn; turn = agent.resume()) {
    for await (const _ of turn) {}
    const result = await turn.result;
    first ??= result;
  }
  return first;
}

const stepsFor = (prompt) => durableWorkloads[promptDirectives(prompt).workload] ?? durableWorkloads["no-tool"];
const neverTools = new Set(Object.entries(durableTools).filter(([, policy]) => policy.replay === "never").map(([name]) => name));
const textOf = (message) => (Array.isArray(message.content) ? message.content.filter((part) => part.type === "text").map((part) => part.text).join("") : String(message.content ?? ""));

const createWorld = worldMode && options.child
  ? (await import(pathToFileURL(join(options["world-root"], "node_modules/@workflow/world-local/dist/index.js")).href)).createWorld
  : null;

if (options.child === "worker") await worker();
else if (options.child === "restorer") await (worldMode ? worldRestorer() : restorer());
else if (options.child === "inspect") await inspect();
else await parent();

// Children: the effects live here (files, stdout, the agent).

function intentStored(path, callId) {
  if (!existsSync(path) || !callId) return false;
  return readFileSync(path, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
    .some((event) => event.type === "tool_intent" && event.data.some((call) => call.id === callId));
}

// A journal in a JSONL file. Each append is one write, so a kill leaves
// whole lines, and writes happen in call order even when calls overlap. Like
// createMemoryJournal, it refuses a batch that does not continue the file, so
// a process whose session was taken over cannot interleave with the new one.
// `step` brackets the write when the worker is stepping.
// Declarations, not consts: the child roles run before this point.
function snapshotSeqOf(bytes) {
  return Number(Buffer.from(bytes).readBigUInt64LE(5));
}

function readEvents(path) {
  const text = existsSync(path) ? readFileSync(path, "utf8") : "";
  return text.split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function fileJournal(path, step = null) {
  let previous = Promise.resolve();
  const snapshotPath = `${path}.snapshot`;
  const journal = {
    append(batch) {
      const written = previous.then(async () => {
        if (step) await step(`journal_before:${batch.map((event) => event.type).join("+")}`);
        const last = (existsSync(path) ? readFileSync(path, "utf8") : "").split("\n").filter(Boolean).at(-1);
        const expected = (last ? JSON.parse(last).seq : 0) + 1;
        if (batch[0].seq !== expected) throw new FxFencedError(`expected seq ${expected}, received ${batch[0].seq}`);
        appendFileSync(path, batch.map((event) => `${JSON.stringify(event)}\n`).join(""));
        if (step) await step("journal_after");
      });
      previous = written;
      return written;
    },
    async load() {
      const events = readEvents(path);
      if (!options.snapshots || !existsSync(snapshotPath)) return { events };
      const snapshot = new Uint8Array(readFileSync(snapshotPath));
      const atSeq = snapshotSeqOf(snapshot);
      return { snapshot, events: events.filter((event) => event.seq > atSeq) };
    },
  };
  if (options.snapshots) {
    journal.snapshot = async (bytes, atSeq) => {
      if (step) await step("snapshot_before");
      if (snapshotSeqOf(bytes) !== atSeq) throw new Error("snapshot header does not match atSeq");
      const last = readEvents(path).at(-1)?.seq ?? 0;
      if (atSeq > last) {
        writeFileSync(`${path}.snapshot-ahead`, `${atSeq} > ${last}\n`);
        throw new Error("a snapshot covers events the journal has not stored");
      }
      // Snapshots only move forward.
      const stored = existsSync(snapshotPath) ? snapshotSeqOf(readFileSync(snapshotPath)) : 0;
      if (atSeq > stored) {
        writeFileSync(`${snapshotPath}.tmp`, bytes);
        renameSync(`${snapshotPath}.tmp`, snapshotPath);
      }
      if (step) await step("snapshot_after");
    };
  }
  return journal;
}

function openWorld() {
  return createWorld({ dataDir: join(options.dir, "world"), recoverActiveRuns: false });
}

// world-local's queue teardown calls undici's Agent.close(), which Bun's
// built-in undici lacks; only that known failure is skipped.
async function closeWorld(world) {
  try {
    await world.close?.();
  } catch (error) {
    if (!(process.versions.bun && error instanceof TypeError && error.message.includes("httpAgent?.close"))) throw error;
  }
}

// The same steps as fileJournal, around another journal's appends.
function steppedJournal(inner, step) {
  let previous = Promise.resolve();
  return {
    append(batch) {
      const written = previous.then(async () => {
        await step(`journal_before:${batch.map((event) => event.type).join("+")}`);
        await inner.append(batch);
        await step("journal_after");
      });
      previous = written.catch(() => {});
      return written;
    },
    load: () => inner.load(),
  };
}

async function worker() {
  // Steps can wait at the same time (a tool's effect and the turn's
  // tool_start event). The parent acks in the order steps were printed, so
  // waiters resolve first in, first out.
  const lines = createInterface({ input: process.stdin });
  let pendingAcks = 0;
  const waiters = [];
  lines.on("line", () => {
    if (waiters.length > 0) waiters.shift()();
    else pendingAcks += 1;
  });
  let stepCount = 0;
  const step = async (name) => {
    stepCount += 1;
    process.stdout.write(`${JSON.stringify({ step: stepCount, name })}\n`);
    if (pendingAcks > 0) {
      pendingAcks -= 1;
      return;
    }
    await new Promise((resolveAck) => { waiters.push(resolveAck); });
  };
  let stepping = false;
  let crashTurn = null;
  let followed = null;
  const sendInputs = () => {
    if (!options.inputs || !crashTurn || followed) return;
    const acks = join(options.dir, "acks.log");
    crashTurn.steer(steerText).then(() => {
      appendFileSync(acks, "steer\n");
      return step("steer_acked");
    }, () => {});
    followed = agent.followUp(followUpText);
    followed.accepted.then(() => {
      appendFileSync(acks, "follow_up\n");
      return step("follow_up_acked");
    }, () => {});
    followed.catch(() => {});
  };
  const run = async (name, _input, context) => {
    sendInputs();
    if (stepping) await step(`before_effect:${name}`);
    // NeverStartsWithoutDurableIntent: the journal already holds this call.
    const stored = worldMode
      ? (await workflow({ world, sessionId: durable.sessionId }).journal.load()).events
        .some((event) => event.type === "tool_intent" && event.data.some((call) => call.id === context?.toolCallId))
      : intentStored(join(options.dir, "journal.jsonl"), context?.toolCallId);
    if (journaled && neverTools.has(name) && !stored) {
      appendFileSync(join(options.dir, "effects.log"), `intent_missing:${name}\n`);
    }
    appendFileSync(join(options.dir, "effects.log"), `${name}\n`);
    if (stepping) await step(`after_effect:${name}`);
    return `${name}:ok`;
  };
  const stepWhenStepping = (name) => (stepping ? step(name) : undefined);
  const world = worldMode ? openWorld() : null;
  await world?.start?.();
  const durable = worldMode ? workflow({ world }) : null;
  const journal = worldMode
    ? steppedJournal(durable.journal, stepWhenStepping)
    : journaled ? fileJournal(join(options.dir, "journal.jsonl"), stepWhenStepping) : undefined;
  // With --snapshots, the worker waits for the snapshot the crash turn's
  // commit takes, so its write is stepped like every other.
  let snapshotTaken = null;
  const onEvent = (event) => {
    if (event.type === "journal.snapshot" || event.type === "journal.snapshot_error") snapshotTaken?.();
  };
  const agent = await createFxAgent({
    ...await agentOptions({ backend: options.backend, fetch: scriptedFetch({ stepsFor }), tools: hostTools(run), journal }),
    onEvent,
  });
  if (worldMode) writeFileSync(join(options.dir, "session.txt"), durable.sessionId);
  for (let index = 0; index < setupTurns; index += 1) {
    const setup = agent.prompt(`workload=no-tool setup ${index}`);
    for await (const _ of setup) {}
    await setup.result;
  }
  if (!journaled) writeFileSync(join(options.dir, "checkpoint.bin"), await agent.checkpoint());
  process.stdout.write(`${JSON.stringify({ ready: true })}\n`);
  const crashSnapshot = new Promise((resolveSnapshot) => { snapshotTaken = resolveSnapshot; });
  stepping = true;
  try {
    const turn = agent.prompt(`workload=${options.workload} crash`);
    crashTurn = turn;
    await step("prompt_sent");
    let sawText = false;
    for await (const event of turn) {
      if (event.type === "text_delta") {
        if (sawText) continue;
        sawText = true;
      }
      if (event.type === "text_delta" || event.type === "tool_start" || event.type === "tool_end") await step(`event:${event.type}`);
    }
    await turn.result;
    await step("result");
    if (options.snapshots) await Promise.race([crashSnapshot, new Promise((resolveWait) => setTimeout(resolveWait, 3000))]);
    if (followed) {
      const next = await followed;
      for await (const _ of next) {}
      await next.result;
      await step("follow_up_result");
    }
    await agent.close();
  } catch (error) {
    // A worker released after a takeover (--race) stops on the fence.
    if (error?.cause?.code !== "FX_FENCED") throw error;
    process.stdout.write(`${JSON.stringify({ fenced: true })}\n`);
    await agent.close().catch(() => {});
  } finally {
    if (world) await closeWorld(world);
    // The ack reader keeps stdin open; release it so the worker can exit.
    lines.close();
    process.stdin.destroy();
  }
}

// The first model request a session restored from `loaded` sends.
async function firstRequest(loaded) {
  let first = null;
  const capture = (prompt) => {
    first ??= JSON.stringify(prompt);
    return stepsFor(prompt);
  };
  const journal = { async append() {}, async load() { return loaded; } };
  const agent = await createFxAgent(await agentOptions({ backend: options.backend, fetch: scriptedFetch({ stepsFor: capture }), tools: hostTools(async () => "inspected"), journal }));
  const turn = agent.prompt("workload=no-tool inspect");
  for await (const _ of turn) {}
  await turn.result;
  await agent.close();
  return first;
}

// The session's journal as its contiguous events, for comparing two points;
// with snapshots, every stored event, the snapshot's seq, and whether the
// snapshot and its tail restore the session every event restores.
async function inspect() {
  let events;
  let snapshotAt = null;
  let snapshotMatches = null;
  let snapshotAhead = false;
  if (worldMode) {
    const world = openWorld();
    await world.start?.();
    events = (await workflow({ world, sessionId: readFileSync(join(options.dir, "session.txt"), "utf8") }).journal.load()).events;
    await closeWorld(world);
  } else {
    const path = join(options.dir, "journal.jsonl");
    events = options.snapshots ? readEvents(path) : (await fileJournal(path).load()).events;
    snapshotAhead = existsSync(`${path}.snapshot-ahead`);
    if (options.snapshots && existsSync(`${path}.snapshot`)) {
      const snapshot = new Uint8Array(readFileSync(`${path}.snapshot`));
      snapshotAt = snapshotSeqOf(snapshot);
      const viaSnapshot = await firstRequest({ snapshot, events: events.filter((event) => event.seq > snapshotAt) });
      snapshotMatches = viaSnapshot !== null && viaSnapshot === await firstRequest({ events });
    }
  }
  const fingerprint = events.map((event) => `${event.seq}:${event.type}:${event.turn}`).join(",");
  process.stdout.write(`${JSON.stringify({ summary: { fingerprint, lastSeq: events.at(-1)?.seq ?? 0, snapshotAt, snapshotMatches, snapshotAhead } })}\n`);
}

async function restorer() {
  const requests = [];
  const run = async (name) => {
    appendFileSync(join(options.dir, "effects.log"), `${name}\n`);
    return `${name}:ok`;
  };
  const checkpointPath = join(options.dir, "checkpoint.bin");
  const journalPath = join(options.dir, "journal.jsonl");
  const opened = [];
  const open = async () => createFxAgent({
    ...await agentOptions({
      backend: options.backend,
      fetch: scriptedFetch({ stepsFor, onRequest: (request) => requests.push(request) }),
      tools: hostTools(run),
      checkpoint: !journaled && existsSync(checkpointPath) ? readFileSync(checkpointPath) : undefined,
      journal: journaled ? fileJournal(journalPath) : undefined,
    }),
    onEvent: (event) => { if (event.type === "journal.open") opened.push(event); },
  });
  let journalFolds = true;
  let agent;
  try {
    agent = await open();
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ summary: { completed: false, rememberedSetup: false, resultCounts: {}, journalFolds: false, error: String(error?.message ?? error) } })}\n`);
    return;
  }
  // The setup turn is always committed. A second committed turn means the
  // crashed turn finished before the kill; an open one is resumed.
  // The setup turns, then the crash turn; a follow-up may have committed one more.
  const committedBeforeOpen = journaled && opened[0]?.turns >= setupTurns + 1;
  let result = { stopReason: "end_turn" };
  const resumed = journaled ? agent.resume() : null;
  if (resumed) {
    for await (const _ of resumed) {}
    result = await resumed.result;
  } else if (!committedBeforeOpen) {
    const turn = agent.prompt(`workload=${options.workload} crash`);
    for await (const _ of turn) {}
    result = await turn.result;
  }
  if (journaled) {
    // Follow-ups the journal held run before the check.
    await resumeAll(agent);
    // Every turn so far must reach the model; a check prompt shows them.
    const check = agent.prompt("workload=no-tool check");
    for await (const _ of check) {}
    await check.result;
  }
  await agent.close();
  if (journaled) {
    try {
      await (await open()).close();
    } catch {
      journalFolds = false;
    }
  }
  const prompt = requests.at(-1)?.body.prompt ?? [];
  const resultCounts = {};
  for (const id of toolResultIds(prompt)) resultCounts[id] = (resultCounts[id] ?? 0) + 1;
  process.stdout.write(`${JSON.stringify({
    summary: {
      completed: result.stopReason === "end_turn",
      rememberedSetup: prompt.some((message) => message.role === "user" && textOf(message).includes("setup")),
      resultCounts,
      journalFolds,
      committedBeforeOpen,
      loadedSnapshot: opened[0]?.snapshot === true,
      ...inputCounts(prompt),
    },
  })}\n`);
}

// The session is in the World alone. Its queue message goes to `handler`,
// which resumes an open turn; then the restorer opens the session itself.
async function worldRestorer() {
  const requests = [];
  const run = async (name) => {
    appendFileSync(join(options.dir, "effects.log"), `${name}\n`);
    return `${name}:ok`;
  };
  const sessionId = readFileSync(join(options.dir, "session.txt"), "utf8");
  const world = openWorld();
  await world.start?.();
  // Wakes queued while the restorer runs are absorbed; the route is called below.
  world.registerHandler(workflowQueuePrefix, async () => new Response(null, { status: 204 }));
  const createAgent = async (durable) => createFxAgent(await agentOptions({
    backend: options.backend,
    fetch: scriptedFetch({ stepsFor, onRequest: (request) => requests.push(request) }),
    tools: hostTools(run),
    journal: durable.journal,
  }));
  const stored = async () => (await workflow({ world, sessionId }).journal.load()).events;
  // Turn 1 is the setup turn and turn 2 the crash turn. The setup turn's
  // result does not wait for its last appends, so a kill can leave either
  // turn open, and the route resumes whichever one is.
  const crashTurn = 2;
  const summary = { completed: false, rememberedSetup: false, resultCounts: {}, journalFolds: true, committedBeforeOpen: false, resumedByHandler: false };
  try {
    const before = await stored();
    summary.committedBeforeOpen = before.some((event) => event.type === "turn_committed" && event.turn === crashTurn);
    let routed = 0;
    const route = workflow({ world, wakeAfterSeconds: 0.001, createAgent: (durable) => { routed += 1; return createAgent(durable); } });
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
    const response = await route.handler(new Request("http://localhost/queue", { method: "POST", body: JSON.stringify({ runId: sessionId }) }));
    if (response.status !== 204) throw new Error(`the route answered ${response.status}`);
    summary.resumedByHandler = routed > 0;
    const after = (await stored()).filter((event) => event.type === "turn_committed");
    summary.commits = after.map((event) => `${event.turn}:${event.data.kind}`);
    const crashCommit = after.find((event) => event.turn === crashTurn);
    const agent = await createAgent(workflow({ world, sessionId }));
    if (crashCommit) summary.completed = crashCommit.data.kind === "assistant";
    else if (!before.some((event) => event.turn === crashTurn)) {
      // No trace of the crash turn reached the World: the host sends it again.
      const turn = agent.prompt(`workload=${options.workload} crash`);
      for await (const _ of turn) {}
      summary.completed = (await turn.result).stopReason === "end_turn";
    }
    await resumeAll(agent);
    const check = agent.prompt("workload=no-tool check");
    for await (const _ of check) {}
    await check.result;
    await agent.close();
    try {
      await (await createAgent(workflow({ world, sessionId }))).close();
    } catch {
      summary.journalFolds = false;
    }
  } catch (error) {
    summary.journalFolds = false;
    summary.error = [error, error?.cause].filter(Boolean).map((value) => `${value.name}: ${value.message}`).join(" <- ");
  }
  await closeWorld(world);
  const prompt = requests.at(-1)?.body.prompt ?? [];
  summary.rememberedSetup = prompt.some((message) => message.role === "user" && textOf(message).includes("setup"));
  Object.assign(summary, inputCounts(prompt));
  for (const id of toolResultIds(prompt)) summary.resultCounts[id] = (summary.resultCounts[id] ?? 0) + 1;
  process.stdout.write(`${JSON.stringify({ summary })}\n`);
}

// Parent: orchestration only.

function runChild(role, settings) {
  return startChild(role, settings).done;
}

// `holdAt` leaves the child waiting at step k until `release()`, which acks
// every step it printed meanwhile and every later one.
function startChild(role, { backend, workload, dir, killAt = Infinity, holdAt = Infinity }) {
  const execArgs = !process.versions.bun && backend === "wasm" ? ["--experimental-wasm-jspi"] : [];
  const child = spawn(process.execPath, [...execArgs, scriptPath, "--child", role, "--mode", options.mode, "--world-root", options["world-root"], ...(options.inputs ? ["--inputs"] : []), ...(options.snapshots ? ["--snapshots"] : []), "--backend", backend, "--workload", workload, "--dir", dir], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const steps = [];
  let summary = null;
  let killedAt = null;
  let heldAt = null;
  let unacked = 0;
  let released = false;
  let fenced = false;
  let reachHold;
  const held = new Promise((resolveHeld) => { reachHold = resolveHeld; });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(-4096); });
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    if (message.summary) summary = message.summary;
    if (message.fenced) fenced = true;
    if (message.step === undefined) return;
    steps.push(message.name);
    if (message.step >= killAt && killedAt === null) {
      killedAt = message.name;
      child.kill("SIGKILL");
    } else if (message.step >= holdAt && !released) {
      unacked += 1;
      if (heldAt === null) {
        heldAt = message.name;
        reachHold();
      }
    } else child.stdin.write("go\n");
  });
  const timer = setTimeout(() => child.kill("SIGKILL"), Number(options["timeout-ms"]));
  const done = new Promise((resolveChild) => {
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      reachHold();
      resolveChild({ code, signal, steps, killedAt, heldAt, fenced, summary, stderr });
    });
  });
  return {
    done,
    held,
    release() {
      released = true;
      for (; unacked > 0; unacked -= 1) child.stdin.write("go\n");
    },
  };
}

async function parent() {
  const backends = listOption(options.backends);
  const workloads = listOption(options.workloads);
  // Children get the JSPI flag themselves; the parent only orchestrates.
  for (const backend of backends) if (!new Set(["native", "wasm"]).has(backend)) throw new Error(`unknown backend: ${backend}`);
  for (const workload of workloads) if (!durableWorkloads[workload]) throw new Error(`unknown workload: ${workload}`);

  const report = {
    format_version: 1,
    mode: options.mode,
    race: options.race,
    inputs: options.inputs,
    snapshots: options.snapshots,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    groups: [],
    violations_by_invariant: {},
    cells: 0,
    failing_cells: 0,
    // Batching can make a run shorter than the clean one, so step k may not
    // exist in it; such a cell tests nothing and is counted apart.
    skipped_cells: 0,
  };
  for (const backend of backends) {
    for (const workload of workloads) {
      const scratch = mkdtempSync(join(tmpdir(), "libfx-crash-"));
      const clean = await runChild("worker", { backend, workload, dir: scratch });
      rmSync(scratch, { recursive: true, force: true });
      if (clean.code !== 0) {
        throw new Error(`${backend} ${workload} clean run failed (${clean.code} ${clean.signal}) after steps [${clean.steps.join(", ")}]: ${clean.stderr}`);
      }
      const group = { backend, workload, steps: clean.steps, cells: [] };
      for (let k = 1; k <= clean.steps.length; k += 1) {
        const dir = mkdtempSync(join(tmpdir(), "libfx-crash-"));
        try {
          let crashed;
          let restored;
          let race = null;
          if (options.race) {
            const worker = startChild("worker", { backend, workload, dir, holdAt: k });
            await worker.held;
            restored = await runChild("restorer", { backend, workload, dir });
            const before = await runChild("inspect", { backend, workload, dir });
            worker.release();
            crashed = await worker.done;
            const after = await runChild("inspect", { backend, workload, dir });
            race = { before: before.summary ?? null, after: after.summary ?? null };
          } else {
            crashed = await runChild("worker", { backend, workload, dir, killAt: k });
          }
          const stoppedAt = options.race ? crashed.heldAt : crashed.killedAt;
          if (stoppedAt === null && crashed.steps.length < k) {
            report.skipped_cells += 1;
            group.cells.push({ k, skipped: true, steps: crashed.steps.length });
            continue;
          }
          if (!options.race) restored = await runChild("restorer", { backend, workload, dir });
          const effects = existsSync(join(dir, "effects.log")) ? readFileSync(join(dir, "effects.log"), "utf8").split("\n").filter(Boolean) : [];
          const cell = {
            k,
            killed_at: stoppedAt,
            killed: options.race ? crashed.heldAt !== null : crashed.signal === "SIGKILL",
            ...(race ? { worker_exit: crashed.code, worker_fenced: crashed.fenced } : {}),
            restorer_exit: restored.code,
            never_effects: effects.filter((name) => neverTools.has(name)).length,
            effects: effects.filter((name) => !name.startsWith("intent_missing:")).length,
            ...(restored.summary ?? { completed: false, rememberedSetup: false, resultCounts: {} }),
          };
          cell.violations = checkCrashCell({
            workload,
            neverEffects: cell.never_effects,
            completed: cell.completed && restored.code === 0,
            rememberedSetup: cell.rememberedSetup,
            resultCounts: cell.resultCounts,
          });
          if (!cell.killed) cell.violations.push(`Harness: worker was not ${options.race ? "held" : "killed"} at step ${k} (${crashed.code} ${crashed.signal})`);
          if (options.inputs) {
            const acks = existsSync(join(dir, "acks.log")) ? readFileSync(join(dir, "acks.log"), "utf8").split("\n").filter(Boolean) : [];
            cell.acks = acks;
            for (const [kind, count] of [["steer", cell.steers ?? 0], ["follow_up", cell.followUps ?? 0]]) {
              if (acks.includes(kind) && count === 0) cell.violations.push(`AckedAreDurable: the acknowledged ${kind} never reached the model`);
              if (count > 1) cell.violations.push(`PlacedOnce: the ${kind} reached the model ${count} times`);
            }
          }
          if (race) {
            const { before, after } = race;
            if (crashed.code !== 0) cell.violations.push(`Harness: the released worker failed (${crashed.code} ${crashed.signal}): ${crashed.stderr.slice(-300)}`);
            if (!before || before.fingerprint !== after?.fingerprint) cell.violations.push("FencedNeverWrites: the released worker changed the session");
            if (before && after && after.snapshotAt !== before.snapshotAt
              && !(after.snapshotAt > (before.snapshotAt ?? 0) && after.snapshotAt <= after.lastSeq)) {
              cell.violations.push(`SnapshotsMoveForward: the snapshot went from ${before.snapshotAt} to ${after.snapshotAt}`);
            }
          }
          if (options.snapshots) {
            const final = race?.after ?? (await runChild("inspect", { backend, workload, dir })).summary;
            if (final?.snapshotAhead) cell.violations.push("SnapshotNotAhead: a snapshot covered events the journal had not stored");
            if (final?.snapshotMatches === false) cell.violations.push("SnapshotMatchesPrefix: the snapshot and its tail restore a different session");
          }
          if (journaled) {
            const missing = effects.filter((name) => name.startsWith("intent_missing:")).length;
            if (missing) cell.violations.push(`NeverStartsWithoutDurableIntent: ${missing} never call(s) started before their intent was stored`);
            if (!cell.journalFolds) cell.violations.push(`JournalFolds: the journal did not reopen${cell.error ? ` (${cell.error})` : ""}`);
          }
          for (const violation of cell.violations) {
            const name = violation.split(":")[0];
            report.violations_by_invariant[name] = (report.violations_by_invariant[name] ?? 0) + 1;
          }
          report.cells += 1;
          if (cell.violations.length) report.failing_cells += 1;
          group.cells.push(cell);
        } finally {
          rmSync(dir, { recursive: true, force: true });
        }
      }
      report.groups.push(group);
    }
  }
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (options["require-clean"] && report.failing_cells > 0) process.exitCode = 1;
}
