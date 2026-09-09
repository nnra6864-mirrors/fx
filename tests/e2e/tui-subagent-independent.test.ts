import { test } from "bun:test";
import assert from "node:assert/strict";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall, heldFakeGatewayFinalText, startDynamicFakeGateway, TmuxSession } from "./tmux-helpers";

const CHILD_TASK = "CHILD_TASK_ONLY";
const CHILD_RESULT = "CHILD_RESULT_EXACT";
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(text).join("\n");
  if (value && typeof value === "object" && "text" in value) return String(value.text);
  return "";
}
function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error: any) { if (error.code === "ESRCH") return false; throw error; }
}
type Receipt = { parent_turn_id: number; child_id: string; work_id: string; delivery_id: string; root_id: string };
type Fixture = Awaited<ReturnType<typeof start>>;

type ParentResponse = (latest: string, body: any) => Response | undefined;
type Mode = "run" | "message" | "parallel" | "approval";
async function start(mode: Mode = "run", limit = 64, parentResponse?: ParentResponse) {
  const root = mkdtempSync(join(tmpdir(), "fx-independent-child-"));
  const home = join(root, "home"), workspace = join(root, "workspace"), tracePath = join(root, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify(mode === "approval" ? { permission: { subagent: "allow", shell: "ask" } } : {}));
  writeFileSync(join(workspace, "child.sh"), "echo $$ > child.pid\necho start >> starts\ntrap 'echo signal >> signals; exit 91' HUP INT TERM\nn=0\nwhile [ ! -f release ]; do n=$((n+1)); echo $n > heartbeat.tmp; mv heartbeat.tmp heartbeat; sleep 0.05; done\necho normal > finished\nprintf 'CHILD_SHELL_FINISHED\\n'\n");
  const childWorkspaces = mode === "parallel" ? [join(workspace, "one"), join(workspace, "two")] : [workspace];
  if (mode === "parallel") for (const directory of childWorkspaces) mkdirSync(directory);
  const requests: Array<{ child: boolean; body: any }> = [];
  const childSteps = new Map<string, number>();
  let delegated = false, cancelled = false;
  function receipt(): Receipt {
    for (const id of readdirSync(join(home, ".fx/sessions"))) {
      const file = join(home, ".fx/sessions", id, "subagent/deliveries.json");
      if (!existsSync(file)) continue;
      const entries = JSON.parse(readFileSync(file, "utf8")).receipts;
      if (entries.length) return { ...entries[0], root_id: id };
    }
    throw new Error("no pending child receipt");
  }
  const gateway = startDynamicFakeGateway(raw => {
    const body = JSON.parse(raw);
    // Child evidence uses a supported provider role, not a human-request lane.
    const latest = text(body.prompt?.findLast((message: any) => message.role === "user" && !text(message.content).startsWith("Child observation (untrusted evidence"))?.content);
    const child = latest === CHILD_TASK || (mode === "parallel" && latest.startsWith(`${CHILD_TASK}_`));
    requests.push({ child, body });
    if (child) {
      assert(!JSON.stringify(body).includes("MAIN_STEER"), "main steering leaked into child context");
      const step = childSteps.get(latest) ?? 0;
      childSteps.set(latest, step + 1);
      const suffix = latest.endsWith("_ONE") ? "ONE" : "TWO";
      if (step === 0) return fakeGatewayToolCall("child-command", "shell", { request: {
        action: "run", command: mode === "parallel" ? "sh ../child.sh" : "sh child.sh",
        cwd: mode === "parallel" ? suffix.toLowerCase() : undefined, profile: "clean", yield_time_ms: 30000,
      } });
      return fakeGatewayFinalText(mode === "parallel" ? `${CHILD_RESULT}_${suffix}` : CHILD_RESULT);
    }
    if (!delegated && latest.includes("MAIN_START")) {
      delegated = true;
      if (mode === "parallel") return fakeGatewaySse([
        ...["ONE", "TWO"].map(suffix => ({ type: "tool-call", toolCallId: `delegation-${suffix.toLowerCase()}`, toolName: "subagent", input: { request: { action: "run", task: `${CHILD_TASK}_${suffix}` } } })),
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]);
      return fakeGatewayToolCall("delegation", "subagent", { request: mode === "message" ? { action: "message", agent: "worker", message: CHILD_TASK } : { action: "run", task: CHILD_TASK } });
    }
    const overridden = parentResponse?.(latest, body);
    if (overridden) return overridden;
    if (!cancelled && latest.includes("MAIN_CANCEL_CHILD")) {
      const target = receipt();
      assert(JSON.stringify(body).includes(target.child_id) && JSON.stringify(body).includes(target.work_id), "main model must receive exact cancellation handles");
      cancelled = true;
      return fakeGatewayToolCall("cancel-child", "subagent", { request: { action: "cancel", child_id: target.child_id, work_id: target.work_id } });
    }
    if (latest.includes("OTHER_SESSION")) return fakeGatewayFinalText("OTHER_SESSION_OK");
    if (latest.includes("AFTER_RETURN")) return fakeGatewayFinalText("RETURN_OK");
    if (latest.includes("MAIN_STEER_TWO")) return fakeGatewayFinalText("MAIN_SECOND_RESPONSE");
    if (latest.includes("MAIN_STEER")) return fakeGatewayFinalText("MAIN_RESPONSE");
    return fakeGatewayFinalText("MAIN_CONTINUED");
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["vision", "file-input", "tool-use"] }] });
  const stderr = join(root, "stderr.log");
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, AI_GATEWAY_API_KEY: "synthetic-independent-child",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_SKIP_ONBOARDING: "1",
    FX_MODEL: FAKE_GATEWAY_MODEL, FX_PERMISSION_MODE: mode === "approval" ? "ask" : "full-access", FX_MAX_AGENT_STEPS: String(limit),
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`, FX_TRACE_LOG: tracePath,
    FX_TRACE_SCOPES: "subagent,agent,worker,tool,session,input", FX_RECORD: join(root, "session.fxtape"),
  };
  let tui: TmuxSession;
  try {
    tui = await TmuxSession.create({ cmd: quote(FX_BIN), cwd: workspace, env, isolated: true, remainOnExit: true, width: 110, height: 35, stderrPath: stderr });
    await tui.waitForStableComposer(15000);
  } catch (error) { gateway.stop(); throw error; }
  const trace = () => existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
  const frames = (id: string) => readFileSync(join(home, ".fx/sessions", id, "events.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  const fixture = { root, home, workspace, childWorkspaces, tui, gateway, requests, receipt, trace, frames, stderr, env };
  return fixture;
}
async function until(f: Fixture, predicate: () => boolean, label: string, milliseconds = 15000) {
  const end = Date.now() + milliseconds;
  while (!predicate()) {
    assert(!f.tui.paneStatus().dead, `fx exited before ${label}; evidence ${f.root}`);
    assert(Date.now() < end, `${label}; evidence ${f.root}`);
    await Bun.sleep(25);
  }
}
async function begin(f: Fixture) {
  await f.tui.sendText("MAIN_START");
  await until(f, () => existsSync(join(f.workspace, "heartbeat")), "child heartbeat");
  return { ...f.receipt(), pid: Number(readFileSync(join(f.workspace, "child.pid"), "utf8")) };
}
async function assertContinues(f: Fixture, pid: number) {
  const before = Number(readFileSync(join(f.workspace, "heartbeat"), "utf8"));
  await until(f, () => Number(readFileSync(join(f.workspace, "heartbeat"), "utf8")) > before, "continued child progress");
  assert(alive(pid), "same child process remains alive");
  assert.equal(Number(readFileSync(join(f.workspace, "child.pid"), "utf8")), pid);
  assert.equal(readFileSync(join(f.workspace, "starts"), "utf8").trim(), "start");
  assert(!existsSync(join(f.workspace, "signals")), "main controls signalled the child");
}
async function releaseAndAdopt(f: Fixture, target: Receipt) {
  writeFileSync(join(f.workspace, "release"), "release");
  await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)), "child evidence reaches main model");
  await until(f, () => f.frames(target.root_id).filter(frame => frame.event?.child_observation?.delivery_id === target.delivery_id).length === 1, "one durable child adoption");
}
async function quit(f: Fixture) {
  await f.tui.sendText("/quit");
  await f.tui.waitForPane(() => f.tui.paneStatus().dead, 10000);
  assert.equal(f.tui.paneStatus().status, 0);
  assert.equal(readFileSync(f.stderr, "utf8"), "");
}
async function exercise(body: (f: Fixture) => Promise<void>, mode: Mode = "run", limit = 64, parentResponse?: ParentResponse) {
  const f = await start(mode, limit, parentResponse);
  let passed = false;
  try { await body(f); passed = true; }
  finally {
    for (const directory of f.childWorkspaces) writeFileSync(join(directory, "release"), "cleanup");
    writeFileSync(join(f.root, "scrollback.txt"), await f.tui.captureFullScrollback().catch(() => ""));
    writeFileSync(join(f.root, "requests.json"), JSON.stringify(f.requests, null, 2));
    await f.tui.kill();
    f.gateway.stop();
    if (!passed) console.error(`Independent-child evidence: ${f.root}`);
  }
}

for (const mode of ["run", "message"] as const) test(`independent ${mode} answers main steering before child completion`, async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER keep the child running");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await assertContinues(f, child.pid);
    assert(f.trace().includes("event=child_parent_wait_released"));
    assert(f.trace().includes("reason=steering child_cancelled=false"));
    await releaseAndAdopt(f, child);
    await quit(f);
    assert(!alive(child.pid));
  }, mode);
}, 60000);

test("main cancellation preserves child and does not create an unsolicited main request", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendKeys("C-c");
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id} outcome_kind=interrupted`), "main interruption");
    await assertContinues(f, child.pid);
    const before = f.requests.filter(request => !request.child).length;
    writeFileSync(join(f.workspace, "release"), "release");
    await until(f, () => existsSync(join(f.workspace, "finished")), "child finishes after main cancellation");
    await Bun.sleep(300);
    assert.equal(f.requests.filter(request => !request.child).length, before, "child completion must not restart the cancelled main task");
    await f.tui.sendText("AFTER_RETURN use any completed child result");
    await f.tui.waitForText("RETURN_OK", 15000);
    await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)), "retained result on next main request");
    await quit(f);
    assert(!alive(child.pid));
  });
}, 60000);

test("main agent cancellation uses exact child work and stops only that work", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER keep running");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await assertContinues(f, child.pid);
    await f.tui.sendText("MAIN_CANCEL_CHILD");
    await until(f, () => f.trace().includes("event=child_cancel_tool_result") && f.trace().includes("source=main_agent"), "main-agent cancellation tool");
    await until(f, () => !alive(child.pid), "cancelled child cleanup");
    await until(f, () => f.frames(child.root_id).some(frame => frame.event?.child_observation?.outcome === "cancelled"), "durable cancelled child outcome");
    await quit(f);
  });
}, 60000);

test("session replacement preserves original child without injecting into the new session", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendKeys("C-c");
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id} outcome_kind=interrupted`), "main interruption before switching");
    await f.tui.sendText("/new");
    await until(f, () => f.trace().includes(`event=child_host_detached root_id=${child.root_id}`), "original host detaches");
    await f.tui.sendText("OTHER_SESSION");
    await f.tui.waitForText("OTHER_SESSION_OK", 15000);
    await assertContinues(f, child.pid);
    const other = f.requests.filter(request => !request.child && JSON.stringify(request.body).includes("OTHER_SESSION"));
    assert(other.length > 0);
    assert(other.every(request => !JSON.stringify(request.body).includes(child.child_id)), "new session must not inherit old child state");
    writeFileSync(join(f.workspace, "release"), "release");
    await until(f, () => existsSync(join(f.workspace, "finished")), "original child finishes while another session is selected");
    await Bun.sleep(300);
    const pending = JSON.parse(readFileSync(join(f.home, ".fx/sessions", child.root_id, "subagent/deliveries.json"), "utf8"));
    assert.equal(pending.receipts.length, 1, "unselected session keeps its result receipt");
    assert(!other.some(request => JSON.stringify(request.body).includes(CHILD_RESULT)));
    await quit(f);
    assert(!alive(child.pid));
  });
}, 60000);

test("fx exit signals and joins a still-running independent child", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await assertContinues(f, child.pid);
    await quit(f);
    assert(!alive(child.pid));
    assert(f.trace().includes(`event=child_host_shutdown_requested root_id=${child.root_id} source=process_exit`));
    assert(f.trace().includes(`event=child_host_joined root_id=${child.root_id}`));
  });
}, 60000);

test("resume preserves the pending acknowledgement and separate child result presentation", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER keep running");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await releaseAndAdopt(f, child);
    await f.tui.waitForText("Subagent finished", 15000);
    await quit(f);
    const resumedStderr = join(f.root, "resumed-stderr.log");
    const resumed = await TmuxSession.create({
      cmd: `${quote(FX_BIN)} --resume ${quote(child.root_id)}`, cwd: f.workspace,
      env: { ...f.env, FX_TRACE_LOG: join(f.root, "resume-trace.log"), FX_RECORD: join(f.root, "resumed.fxtape") },
      isolated: true, remainOnExit: true, width: 110, height: 35, stderrPath: resumedStderr,
    });
    try {
      await resumed.waitForText("Subagent still running", 15000);
      await resumed.waitForText("Subagent finished", 15000);
      await resumed.sendKeys("C-o");
      await resumed.waitForPane(pane => pane.replace(/\s/g, "").includes(CHILD_RESULT), 15000);
      await resumed.sendKeys("Escape");
      await resumed.waitForPane(pane => !pane.includes("Full detail · ctrl o close"), 15000);
      await resumed.sendText("/quit");
      await resumed.waitForPane(() => resumed.paneStatus().dead, 10000);
      assert.equal(resumed.paneStatus().status, 0);
      assert.equal(readFileSync(resumedStderr, "utf8"), "");
    } finally {
      writeFileSync(join(f.root, "resumed-scrollback.txt"), await resumed.captureFullScrollback().catch(() => ""));
      await resumed.kill();
    }
  });
}, 60000);

test("no-steering completion uses one terminal tool result and no late observation", async () => {
  await exercise(async f => {
    const child = await begin(f);
    writeFileSync(join(f.workspace, "release"), "release");
    await f.tui.waitForText("MAIN_CONTINUED", 15000);
    const receipts = join(f.home, ".fx/sessions", child.root_id, "subagent/deliveries.json");
    await until(f, () => JSON.parse(readFileSync(receipts, "utf8")).receipts.length === 0, "terminal original result retirement");
    const events = f.frames(child.root_id).map(frame => frame.event);
    assert.equal(events.filter(event => event?.tool_result?.child_delivery?.state === "terminal").length, 1);
    assert.equal(events.filter(event => event?.child_observation).length, 0);
    assert(f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)));
    await quit(f);
  });
}, 60000);

for (const reopen of [false, true]) test(`a leftover receipt cannot redeliver a saved terminal result with reopen=${reopen}`, async () => {
  await exercise(async f => {
    const child = await begin(f);
    const path = join(f.home, ".fx/sessions", child.root_id, "subagent/deliveries.json");
    const reserved = readFileSync(path);
    writeFileSync(join(f.workspace, "release"), "release");
    await f.tui.waitForText("MAIN_CONTINUED", 15000);
    await until(f, () => JSON.parse(readFileSync(path, "utf8")).receipts.length === 0, "original result saved and receipt retired");
    assert.equal(f.frames(child.root_id).filter(frame => frame.event?.tool_result?.child_delivery?.state === "terminal").length, 1);
    if (reopen) {
      await quit(f);
      await f.tui.kill();
    }
    // Restore the exact pre-retirement index to model a failed receipt cleanup.
    writeFileSync(path, reserved);
    if (reopen) {
      f.tui = await TmuxSession.create({
        cmd: `${quote(FX_BIN)} --resume ${quote(child.root_id)}`, cwd: f.workspace,
        env: { ...f.env, FX_RECORD: join(f.root, "reconciled.fxtape") }, isolated: true,
        remainOnExit: true, width: 110, height: 35, stderrPath: f.stderr,
      });
      await f.tui.waitForStableComposer(15000);
    }
    await f.tui.sendText("AFTER_RETURN");
    await f.tui.waitForText("RETURN_OK", 15000);
    await until(f, () => JSON.parse(readFileSync(path, "utf8")).receipts.length === 0, "leftover receipt reconciled");
    assert.equal(f.frames(child.root_id).filter(frame => frame.event?.child_observation).length, 0, "terminal original result already adopted this delivery");
    await quit(f);
  });
}, 60000);

test("child completion during a main stream waits for the settled boundary", async () => {
  const held = heldFakeGatewayFinalText();
  let entered = false;
  try {
    await exercise(async f => {
      const child = await begin(f);
      await f.tui.sendText("MAIN_STEER keep streaming");
      await until(f, () => entered, "main stream held");
      await assertContinues(f, child.pid);
      writeFileSync(join(f.workspace, "release"), "release");
      await until(f, () => f.trace().includes("event=child_delivery_outcome_synced"), "child outcome published during stream");
      await Bun.sleep(300);
      assert.equal(f.requests.filter(request => !request.child).length, 2, "no concurrent main request");
      assert.equal(f.frames(child.root_id).filter(frame => frame.event?.child_observation).length, 0);
      held.release("MAIN_STREAM_FINISHED");
      await until(f, () => f.frames(child.root_id).filter(frame => frame.event?.child_observation?.delivery_id === child.delivery_id).length === 1, "completion adopted after stream");
      await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)), "adopted evidence reaches the next model request");
      await quit(f);
    }, "run", 64, latest => {
      if (!entered && latest.includes("MAIN_STEER")) { entered = true; return held.response; }
    });
  } finally { held.dispose(); }
}, 60000);

test("cancelling the main stream after yield leaves the same child alive", async () => {
  const held = heldFakeGatewayFinalText();
  let entered = false;
  try {
    await exercise(async f => {
      const child = await begin(f);
      await f.tui.sendText("MAIN_STEER keep streaming");
      await until(f, () => entered, "main stream held after yield");
      await f.tui.sendKeys("C-c");
      await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id} outcome_kind=interrupted`), "stream interruption");
      await assertContinues(f, child.pid);
      assert.equal(f.requests.filter(request => !request.child).length, 2);
      await f.tui.sendText("AFTER_RETURN");
      await f.tui.waitForText("RETURN_OK", 15000);
      await releaseAndAdopt(f, child);
      await quit(f);
    }, "run", 64, latest => {
      if (!entered && latest.includes("MAIN_STEER")) { entered = true; return held.response; }
    });
  } finally { held.dispose(); }
}, 60000);

test("main provider failure retains child work without an unsolicited retry turn", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER fail only the parent");
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id}`), "failed main execution ends");
    await assertContinues(f, child.pid);
    const before = f.requests.filter(request => !request.child).length;
    assert(before >= 2);
    writeFileSync(join(f.workspace, "release"), "release");
    await until(f, () => f.trace().includes("event=child_delivery_outcome_synced"), "child completes after main failure");
    await Bun.sleep(300);
    assert.equal(f.requests.filter(request => !request.child).length, before);
    await f.tui.sendText("AFTER_RETURN");
    await f.tui.waitForText("RETURN_OK", 15000);
    await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)), "failed main result retained for later input");
    await quit(f);
  }, "run", 64, latest => latest.includes("MAIN_STEER")
    ? Response.json({ error: { message: "synthetic parent failure" } }, { status: 400 }) : undefined);
}, 60000);

test("exhausted main budget does not stop the child or spend another model request", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER final permitted step");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id}`), "main budget boundary");
    await assertContinues(f, child.pid);
    writeFileSync(join(f.workspace, "release"), "release");
    await until(f, () => f.trace().includes("event=child_delivery_outcome_synced"), "child completes after main budget");
    await Bun.sleep(300);
    assert.equal(f.requests.filter(request => !request.child).length, 2);
    await f.tui.sendText("AFTER_RETURN");
    await f.tui.waitForText("RETURN_OK", 15000);
    await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)), "budget-ended main result retained");
    await quit(f);
  }, "run", 2);
}, 60000);

test("rich-input handoff keeps image data on the main agent and preserves child execution", async () => {
  await exercise(async f => {
    const child = await begin(f);
    const image = join(f.workspace, "handoff.png");
    copyFileSync(join(import.meta.dir, "fixtures/favicon.png"), image);
    await f.tui.sendText(`/image ${image}`);
    await f.tui.waitForText("attached image: handoff.png", 15000);
    await f.tui.sendText("MAIN_STEER use this image");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await assertContinues(f, child.pid);
    assert(f.trace().includes("reason=handoff child_cancelled=false"));
    const imageData = readFileSync(image).toString("base64");
    const requests = f.requests.filter(request => !request.child);
    assert(requests.some(request => request.body.prompt.some((message: any) => Array.isArray(message.content) && message.content.some((part: any) => part.type === "file" && part.data === imageData))));
    assert(f.requests.filter(request => request.child).every(request => !JSON.stringify(request.body.prompt).includes(imageData)));
    await releaseAndAdopt(f, child);
    await quit(f);
  });
}, 60000);

test("switching back reattaches the live original host without recovery or restart", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendKeys("C-c");
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id}`), "main interruption");
    await f.tui.sendText("/new");
    await until(f, () => f.trace().includes(`event=child_host_detached root_id=${child.root_id}`), "host detach");
    await f.tui.sendText("OTHER_SESSION");
    await f.tui.waitForText("OTHER_SESSION_OK", 15000);
    await assertContinues(f, child.pid);
    await f.tui.sendText("/resume");
    await f.tui.waitForText("Resume", 15000);
    await f.tui.sendLiteral("MAIN_START");
    await f.tui.sendKeys("Enter");
    await until(f, () => f.trace().includes(`event=child_host_attached root_id=${child.root_id}`), "retained host reattachment");
    await assertContinues(f, child.pid);
    await f.tui.sendText("AFTER_RETURN");
    await f.tui.waitForText("RETURN_OK", 15000);
    await releaseAndAdopt(f, child);
    await quit(f);
    await f.tui.kill();
    f.tui = await TmuxSession.create({
      cmd: `${quote(FX_BIN)} --continue`, cwd: f.workspace,
      env: { ...f.env, FX_RECORD: join(f.root, "continued.fxtape"), FX_TRACE_LOG: join(f.root, "continued-trace.log") },
      isolated: true, remainOnExit: true, width: 110, height: 35, stderrPath: f.stderr,
    });
    await f.tui.waitForStableComposer(15000);
    const continued = await f.tui.captureFullScrollback();
    assert(continued.includes("MAIN_START"), "continuation remembers the explicitly reselected retained session");
    assert(!continued.includes("OTHER_SESSION"));
    await quit(f);
  });
}, 60000);

test("parallel children preserve completed and running result identities across steering", async () => {
  await exercise(async f => {
    await f.tui.sendText("MAIN_START");
    await until(f, () => f.childWorkspaces.every(directory => existsSync(join(directory, "heartbeat"))), "both child processes running");
    const root = f.receipt().root_id;
    const receiptsPath = join(f.home, ".fx/sessions", root, "subagent/deliveries.json");
    const receipts = JSON.parse(readFileSync(receiptsPath, "utf8")).receipts;
    assert.equal(receipts.length, 2);
    assert.equal(new Set(receipts.map((entry: any) => entry.child_id)).size, 2);
    const second = receipts.find((entry: any) => entry.tool_call_id === "delegation-two");
    assert(second);
    writeFileSync(join(f.childWorkspaces[0]!, "release"), "release first");
    await until(f, () => f.requests.some(request => request.child && JSON.stringify(request.body).includes("CHILD_SHELL_FINISHED")), "first child command settles");
    await until(f, () => f.trace().includes("event=child_delivery_outcome_synced"), "first child outcome published");
    assert.equal(f.requests.filter(request => !request.child).length, 1);
    await f.tui.sendText("MAIN_STEER keep the second child running");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    const secondDirectory = f.childWorkspaces[1]!;
    const pid = Number(readFileSync(join(secondDirectory, "child.pid"), "utf8"));
    const heartbeat = Number(readFileSync(join(secondDirectory, "heartbeat"), "utf8"));
    await until(f, () => Number(readFileSync(join(secondDirectory, "heartbeat"), "utf8")) > heartbeat, "second child continues");
    assert(alive(pid));
    assert(!existsSync(join(secondDirectory, "signals")));
    writeFileSync(join(secondDirectory, "release"), "release second");
    await until(f, () => f.requests.some(request => !request.child && JSON.stringify(request.body).includes(`${CHILD_RESULT}_TWO`)), "second result reaches main");
    await until(f, () => JSON.parse(readFileSync(receiptsPath, "utf8")).receipts.length === 0, "both receipts retired");
    const events = f.frames(root).map(frame => frame.event);
    assert.equal(events.filter(event => event?.tool_result?.child_delivery?.state === "terminal").length, 1);
    assert.equal(events.filter(event => event?.tool_result?.child_delivery?.state === "running").length, 1);
    const observations = events.filter(event => event?.child_observation).map(event => event.child_observation);
    assert.equal(observations.length, 1);
    assert.equal(observations[0].child_id, second.child_id);
    assert.equal(observations[0].work_id, second.work_id);
    await quit(f);
    assert(!alive(pid));
  }, "parallel");
}, 60000);

for (const allow of [false, true]) test(`dismissing child approval preserves its request until deliberate allow=${allow}`, async () => {
  await exercise(async f => {
    await f.tui.sendText("MAIN_START");
    await until(f, () => f.trace().includes("event=child_approval_registered"), "child approval registered");
    await f.tui.waitForText("sh child.sh", 15000);
    const child = f.receipt();
    assert(!existsSync(join(f.workspace, "starts")));
    await f.tui.sendKeys("Escape");
    await until(f, () => f.trace().includes(`event=prompt_finish turn_id=${child.parent_turn_id} outcome_kind=interrupted`), "main stops while child approval stays pending");
    assert(!f.trace().includes("event=child_approval_response_routing"));
    assert(!f.trace().includes("event=child_cancel_requested"));
    assert.equal(f.receipt().work_id, child.work_id);
    const beforeAnswer = f.trace().length;
    await f.tui.sendText("MAIN_STEER leave that decision to me");
    await until(f, () => f.trace().slice(beforeAnswer).split("\n").some(line => line.includes("event=assistant_completion") && !line.includes("subagent_id=") && line.includes("tool_call_count=0")), "main answers while the child needs human permission");
    await f.tui.waitForText("sh child.sh", 15000);
    await f.tui.sendKeys(allow ? "1" : "3");
    await until(f, () => f.trace().includes("event=child_approval_response_applied"), "deliberate child permission response applied");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    if (allow) {
      await until(f, () => existsSync(join(f.workspace, "heartbeat")), "approved child command starts");
      const pid = Number(readFileSync(join(f.workspace, "child.pid"), "utf8"));
      await assertContinues(f, pid);
      await releaseAndAdopt(f, child);
    } else {
      await until(f, () => f.requests.filter(request => request.child).length === 2, "child receives its denied tool result");
      assert(!existsSync(join(f.workspace, "starts")));
      assert(!f.trace().includes("event=child_cancel_requested"));
    }
    await quit(f);
  }, "approval");
}, 60000);

for (const mode of ["run", "message"] as const) test(`noninteractive ${mode} keeps synchronous delivery without interactive receipts`, async () => {
  await exercise(async f => {
    writeFileSync(join(f.workspace, "release"), "release");
    const result = await runFx(["ask", "--json", "MAIN_START"], {
      cwd: f.workspace, env: { ...f.env, FX_RECORD: join(f.root, "ask.fxtape"), FX_TRACE_LOG: join(f.root, "ask-trace.log") },
    });
    assert.equal(result.code, 0);
    assert.equal(result.stderr, `${mode === "run" ? "Subagent" : "worker"} working · ${CHILD_TASK}\n`);
    const root = JSON.parse(result.stdout).session_id;
    assert(root);
    assert(f.requests.some(request => !request.child && JSON.stringify(request.body).includes(CHILD_RESULT)));
    assert(!existsSync(join(f.home, ".fx/sessions", root, "subagent/deliveries.json")));
    const events = f.frames(root).map(frame => frame.event);
    assert.equal(events.filter(event => event?.child_observation).length, 0);
    assert.equal(events.filter(event => event?.tool_result?.child_delivery).length, 0);
    assert.equal(readFileSync(join(f.workspace, "starts"), "utf8").trim(), "start");
    await quit(f);
  }, mode);
}, 60000);

test("parked steering does not consume an extra empty main-agent step", async () => {
  await exercise(async f => {
    const child = await begin(f);
    await f.tui.sendText("MAIN_STEER keep running");
    await f.tui.waitForText("MAIN_RESPONSE", 15000);
    await f.tui.sendText("MAIN_STEER_TWO keep running");
    await f.tui.waitForText("MAIN_SECOND_RESPONSE", 15000);
    await assertContinues(f, child.pid);
    assert.equal(f.requests.filter(request => !request.child).length, 3);
    await quit(f);
    assert(!alive(child.pid));
  }, "run", 3);
}, 60000);
