// Imported by session-recovery.test.ts; inherits that PGSO owner's classification.
// Opt-in red witnesses. Only the freshly built checkout binary is used.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../../evals/eval-helpers";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeShellRun, startFakeGateway, TmuxSession, tmuxAvailable } from "../tmux-helpers";

async function waitForFile(path: string) {
  const deadline = Date.now() + 15_000;
  while (!existsSync(path)) {
    if (Date.now() > deadline) throw new Error(`fixture did not reach controlled boundary: ${path}`);
    await Bun.sleep(10);
  }
}

// No timeout races decide the crash point: the external shell publishes the
// effect, then waits at a gate while the test kills its exact owning fx process.
describe.skipIf(process.env.FX_JOURNAL_RED !== "1")("journal witness native crash", () => {
  test.skipIf(!tmuxAvailable())("fx -c preserves the selected call after effect but before result", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-journal-native-")));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home); mkdirSync(workspace);
    const effect = join(workspace, "external-effect");
    const release = join(workspace, "release");
    const settled = join(workspace, "external-settled");
    const callId = "JOURNAL_ORIGINAL_SELECTED_CALL";
    const command = "printf '%s' $$ > external-pid; printf once > external-effect; while [ ! -f release ]; do sleep 0.01; done; printf settled > external-settled";
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
      const stderrPath = join(root, "resume.stderr");
      resumed = await TmuxSession.create({
        cmd: `${JSON.stringify(FX_BIN)} -c`, cwd: workspace, env,
        isolated: true, stderrPath,
      });
      await resumed.waitForStableComposer();
      // Ordinary -c must stay paused. This is not an upgrade handoff token.
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(effect, "utf8")).toBe("once");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readdirSync(join(home, ".fx", "sessions"), { withFileTypes: true })
        .filter((entry) => entry.isDirectory()).map((entry) => entry.name)).toEqual([sessionId]);
      const sessionDirectory = join(home, ".fx", "sessions", sessionId);
      const log = ["session.json", "events.jsonl"].map((name) =>
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
});
