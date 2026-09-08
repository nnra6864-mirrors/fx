// Imported by session-recovery.test.ts; inherits that PGSO owner's classification.
// Only the freshly built checkout binary is used.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../../evals/eval-helpers";
import { createProjection } from "../../../sdk/transcript.js";
import { decodeNativeJournal } from "./storage";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeShellRun, startFakeGateway, TmuxSession, tmuxAvailable } from "../tmux-helpers";

async function waitForFile(path: string) {
  const deadline = Date.now() + 15_000;
  while (!existsSync(path)) {
    if (Date.now() > deadline) throw new Error(`fixture did not reach controlled boundary: ${path}`);
    await Bun.sleep(10);
  }
}

describe("journal witness native ask", () => {
  test.skipIf(!tmuxAvailable())("interactive creation persists history for a second process", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-journal-interactive-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home); mkdirSync(workspace);
    const gateway = startFakeGateway([fakeGatewayFinalText("interactive journal answer"), fakeGatewayFinalText("reopened journal answer")]);
    const env = {
      HOME: home, AI_GATEWAY_API_KEY: "fixture-key", VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0",
    };
    const stderrPath = join(root, "interactive.stderr");
    let terminal: TmuxSession | undefined;
    try {
      terminal = await TmuxSession.create({ cmd: JSON.stringify(FX_BIN), cwd: workspace, env, isolated: true, stderrPath });
      await terminal.waitForStableComposer();
      await terminal.sendText("Create an interactive journal turn");
      await terminal.waitForText("interactive journal answer");
      await terminal.waitForStableComposer();
      expect(await terminal.captureFullScrollback()).toContain("interactive journal answer");
      await terminal.kill();
      terminal = undefined;
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const ids = readdirSync(join(home, ".fx", "sessions"), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name);
      expect(ids).toHaveLength(1);
      const id = ids[0]!;
      const directory = join(home, ".fx", "sessions", id);
      expect(existsSync(join(directory, "execution.journal"))).toBe(true);
      expect(existsSync(join(directory, "events.jsonl"))).toBe(false);
      const reopened = await runFx(["ask", "--json", "--resume-id", id, "Read the saved interactive turn"], { cwd: workspace, env });
      expect(reopened, JSON.stringify(reopened)).toMatchObject({ code: 0, stderr: "" });
      expect(reopened.stdout).toContain("reopened journal answer");
      expect(gateway.requests).toHaveLength(2);
      expect(JSON.stringify(gateway.requests[1])).toContain("interactive journal answer");
    } finally {
      await terminal?.kill();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  }, 40_000);

  test("saved tools and completed history reopen through the journal", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-journal-ask-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home); mkdirSync(workspace);
    const gateway = startFakeGateway([
      fakeShellRun("journal-saved-call", "printf journal-effect > effect.txt; printf journal-tool-result", { profile: "clean" }),
      fakeGatewayFinalText("journal first answer"),
      fakeGatewayFinalText("journal second answer"),
    ]);
    const env = {
      HOME: home, AI_GATEWAY_API_KEY: "fixture-key", VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0",
    };
    try {
      const first = await runFx(["ask", "--json", "--yolo", "Save the first journal turn"], { cwd: workspace, env, timeoutMs: 30_000 });
      expect(first, JSON.stringify(first)).toMatchObject({ code: 0, signal: null, timedOut: false });
      expect(first.stderr).not.toMatch(/panic|error:|assertion failed|abort trap/i);
      expect(first.stdout).toContain("journal first answer");
      expect(readFileSync(join(workspace, "effect.txt"), "utf8")).toBe("journal-effect");
      const ids = readdirSync(join(home, ".fx", "sessions"), { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name);
      expect(ids).toHaveLength(1);
      const id = ids[0]!;
      const directory = join(home, ".fx", "sessions", id);
      expect(JSON.parse(readFileSync(join(directory, "session.json"), "utf8")).schema_version).toBe(5);
      expect(existsSync(join(directory, "execution.journal"))).toBe(true);
      expect(existsSync(join(directory, "events.jsonl"))).toBe(false);
      expect(existsSync(join(directory, "recovery.json"))).toBe(false);
      const before = readFileSync(join(directory, "execution.journal"));
      const entries = decodeNativeJournal(before);
      const transcript = createProjection(entries).transcript();
      expect(JSON.stringify(transcript)).toContain("journal first answer");
      expect(JSON.stringify(transcript)).toContain("journal-tool-result");
      const detail = await runFx(["session", "--id", id, "--json"], { cwd: workspace, env, timeoutMs: 30_000 });
      expect(detail, JSON.stringify(detail)).toMatchObject({ code: 0, stderr: "" });
      expect(detail.stdout).toContain("journal first answer");
      expect(readFileSync(join(directory, "execution.journal"))).toEqual(before);
      // Replay the valid durable prefix left by a crash after the final model
      // decision, before turn_end. The tool result and decision remain intact.
      const last = entries.at(-1)!;
      const lastFrame = before.length - 84 - last.bytes.length;
      expect(last.kind).toBe("turn_end");
      writeFileSync(join(directory, "execution.journal"), before.subarray(0, lastFrame));
      const finished = await runFx(["ask", "--json", "--yolo", "--resume-id", id, "--continue-recovery"], { cwd: workspace, env, timeoutMs: 30_000 });
      expect(finished, JSON.stringify(finished)).toMatchObject({ code: 0, signal: null, timedOut: false });
      expect(finished.stdout).toContain("journal first answer");
      expect(gateway.requests).toHaveLength(2);
      expect(readFileSync(join(workspace, "effect.txt"), "utf8")).toBe("journal-effect");
      const second = await runFx(["ask", "--json", "--yolo", "--resume-id", id, "Continue with a second journal turn"], { cwd: workspace, env, timeoutMs: 30_000 });
      expect(second, JSON.stringify(second)).toMatchObject({ code: 0, signal: null, timedOut: false });
      expect(second.stderr).not.toMatch(/panic|error:|assertion failed|abort trap/i);
      expect(second.stdout).toContain("journal second answer");
      expect(gateway.requests).toHaveLength(3);
      expect(JSON.stringify(gateway.requests[2])).toContain("journal first answer");
      expect(JSON.stringify(gateway.requests[2])).toContain("journal-tool-result");
      const final = await runFx(["session", "--id", id, "--json"], { cwd: workspace, env, timeoutMs: 30_000 });
      expect(final, JSON.stringify(final)).toMatchObject({ code: 0, stderr: "" });
      expect(final.stdout).toContain("journal first answer");
      expect(final.stdout).toContain("journal second answer");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  }, 90_000);
});

// No timeout races decide the crash point: the external shell publishes the
// effect, then waits at a gate while the test kills its exact owning fx process.
describe("journal witness native crash", () => {
  for (const surface of ["ask", "tui"] as const) {
  test.skipIf(surface === "tui" && !tmuxAvailable())(`${surface} preserves the selected call after effect but before result`, async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-journal-native-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home); mkdirSync(workspace);
    const effect = join(workspace, "external-effect");
    const release = join(workspace, "release");
    const settled = join(workspace, "external-settled");
    const callId = "JOURNAL_ORIGINAL_SELECTED_CALL";
    const command = "printf '%s' $$ > external-pid; printf once >> external-effect; while [ ! -f release ]; do sleep 0.01; done; printf settled > external-settled";
    const gateway = startFakeGateway([
      fakeShellRun(callId, command, { profile: "clean" }),
      fakeGatewayFinalText("UNEXPECTED_AUTOMATIC_MODEL_REPLAY"),
    ]);
    const env = {
      PATH: process.env.PATH,
      HOME: home,
      AI_GATEWAY_API_KEY: "fixture-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0",
    };
    let original: ReturnType<typeof Bun.spawn> | undefined;
    let resumed: TmuxSession | undefined;
    let stderr = Promise.resolve("");
    try {
      original = Bun.spawn([FX_BIN, "ask", "--json", "--yolo", "Perform the fixture effect, then finish."], {
        cwd: workspace, env, stdout: "pipe", stderr: "pipe",
      });
      stderr = new Response(original.stderr).text();
      // Drain output so backpressure cannot choose our cut point.
      const stdout = new Response(original.stdout).text();
      await Promise.race([
        waitForFile(effect),
        original.exited.then(async (code) => {
          throw new Error(`fixture exited before effect: code=${code}, stdout=${await stdout}, stderr=${await stderr}`);
        }),
      ]);
      const sessions = readdirSync(join(home, ".fx", "sessions"));
      expect(sessions).toHaveLength(1);
      const sessionId = sessions[0]!;
      original.kill("SIGKILL");
      await original.exited;
      expect(original.signalCode).toBe("SIGKILL");
      expect(await stderr).not.toMatch(/panic|thread .* crashed|assertion failed|abort trap/i);
      writeFileSync(release, "release");
      expect(gateway.requests).toHaveLength(1);
      const sessionDirectory = join(home, ".fx", "sessions", sessionId);
      const journalPath = join(sessionDirectory, "execution.journal");
      const savedJournal = readFileSync(journalPath);
      expect(savedJournal.toString()).toContain(callId);
      expect(savedJournal.toString()).toContain("external-effect");
      const detail = await runFx(["session", "--id", sessionId, "--json"], { cwd: workspace, env });
      expect(detail, JSON.stringify(detail)).toMatchObject({ code: 0, stderr: "" });
      expect(detail.stdout).toContain(callId);
      expect(detail.stdout).toContain("external-effect");
      expect(readFileSync(journalPath)).toEqual(savedJournal);
      if (surface === "ask") {
        const blocked = await runFx(["ask", "--json", "--yolo", "--resume-id", sessionId, "--continue-recovery"], { cwd: workspace, env });
        expect(blocked.code).not.toBe(0);
        expect(`${blocked.stdout}\n${blocked.stderr}`).toMatch(/RecoveryRequired|reconciliation|recovery required/i);
        expect(gateway.requests).toHaveLength(1);
        expect(readFileSync(effect, "utf8")).toBe("once");
        expect(readFileSync(journalPath)).toEqual(savedJournal);
        return;
      }
      const stderrPath = join(root, "resume.stderr");
      resumed = await TmuxSession.create({
        cmd: `${JSON.stringify(FX_BIN)} -c`, cwd: workspace, env,
        isolated: true, stderrPath,
      });
      try {
        await resumed.waitForStableComposer();
      } catch (error) {
        throw new Error(`${error}\nStartup stderr:\n${readFileSync(stderrPath, "utf8")}`);
      }
      // Ordinary -c must stay paused. This is not an upgrade handoff token.
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(effect, "utf8")).toBe("once");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readdirSync(join(home, ".fx", "sessions"), { withFileTypes: true })
        .filter((entry) => entry.isDirectory()).map((entry) => entry.name)).toEqual([sessionId]);
      const log = ["session.json", "execution.journal"].map((name) =>
        readFileSync(join(sessionDirectory, name), "utf8")).join("\n");
      // The transcript and exact original decision must remain recoverable.
      // A generic 'tool state uncertain' bit without id/name/input is insufficient.
      expect(log).toContain(callId);
      expect(log).toContain("external-effect");
    } finally {
      // Release the external tool even if an earlier assertion fails; never
      // leave a gate-waiting orphan after a deliberately killed owner.
      writeFileSync(release, "release");
      if (original && original.exitCode === null) { original.kill("SIGKILL"); await original.exited; }
      await resumed?.kill();
      gateway.stop();
      const pidFile = join(workspace, "external-pid");
      if (existsSync(pidFile) && !existsSync(settled)) {
        const pid = Number(readFileSync(pidFile, "utf8"));
        if (Number.isSafeInteger(pid) && pid > 1) {
          try { process.kill(pid, "SIGKILL"); } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
          }
        }
      }
      rmSync(root, { recursive: true, force: true });
    }
  }, 30_000);
  }
});
