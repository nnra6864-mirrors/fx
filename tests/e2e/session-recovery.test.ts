import { describe, expect, test } from "bun:test";
import {
  appendFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

function createFixture(prefix: string) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
  };
}

function gatewayEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "session-recovery-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
  };
}

async function createSavedSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
): Promise<string> {
  const created = await runFx(
    ["ask", "--json", "--auto", "Create the first saved turn."],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
  expect(created.code).toBe(0);
  expect(created.stderr).toBe("");
  return JSON.parse(created.stdout).session_id;
}

async function continueSession(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  sessionId: string,
  latest = false,
) {
  return runFx(
    [
      "ask",
      "--json",
      "--auto",
      ...(latest ? ["--resume", "last"] : ["--resume-id", sessionId]),
      "Continue after recovery.",
    ],
    {
      cwd: fixture.workspace,
      env: gatewayEnv(fixture, gateway),
      timeoutMs: TIMEOUT,
    },
  );
}

describe("session recovery", () => {
  test.skipIf(!tmuxAvailable())("resume picker discovers a checkpoint from an unfinished first turn", async () => {
    const fixture = createFixture("fx-session-first-checkpoint-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("CHECKPOINT_TURN_RECOVERED"),
    ]);
    let tui: TmuxSession | null = null;
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const eventsPath = join(fixture.home, ".fx", "sessions", sessionId, "events.jsonl");
      const checkpoint = [
        { user: { text: "unfinished first request", images: [], work_id: null } },
        { context_checkpoint: { covers_through_seq: 1, summary: "<context_handoff>FIRST_CHECKPOINT_FACT</context_handoff>" } },
      ].map((event, index) => JSON.stringify({
        schema_version: 1, seq: index + 1, timestamp_ms: Date.now(), event,
      })).join("\n") + "\n";
      writeFileSync(eventsPath, checkpoint, { mode: 0o600 });
      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(JSON.parse(listed.stdout).sessions[0].history_len).toBe(0);
      expect(JSON.parse(listed.stdout).sessions[0]).not.toHaveProperty("has_checkpoint");
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);

      const stderrPath = join(fixture.root, "tui.stderr");
      tui = await TmuxSession.create({ cwd: fixture.workspace, env: gatewayEnv(fixture, gateway), stderrPath });
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("/resume");
      await tui.waitForText("Create the first saved turn.", TIMEOUT);
      expect(readFileSync(eventsPath, "utf8")).toBe(checkpoint);
      await tui.sendKeys("Enter");
      await tui.waitForText("unfinished first request", TIMEOUT);
      await tui.waitForComposer(TIMEOUT);
      await tui.sendText("Continue after checkpoint.");
      await tui.waitForPane(() => readFileSync(eventsPath, "utf8").includes("CHECKPOINT_TURN_RECOVERED"), TIMEOUT);
      await tui.sendText("/quit");
      expect(await tui.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).toContain("FIRST_CHECKPOINT_FACT");
    } finally {
      await tui?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  test("latest resume discovers and repairs a partial final JSONL record", async () => {
    const fixture = createFixture("fx-session-partial-record-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
      fakeGatewayFinalText("PARTIAL_RECORD_RECOVERED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const sessionDir = join(fixture.home, ".fx", "sessions", sessionId);
      const eventsPath = join(sessionDir, "events.jsonl");
      const committed = readFileSync(eventsPath, "utf8");
      appendFileSync(eventsPath, '{"schema_version":1,"partial-tail"');

      const listed = await runFx(["sessions", "--json"], {
        cwd: fixture.workspace,
        env: gatewayEnv(fixture, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(listed.stderr).toBe("");
      expect(JSON.parse(listed.stdout).sessions.map((entry: { id: string }) => entry.id))
        .toContain(sessionId);
      expect(readFileSync(eventsPath, "utf8")).toBe(committed + '{"schema_version":1,"partial-tail"');

      const resumed = await continueSession(fixture, gateway, sessionId, true);
      expect(resumed.code).toBe(0);
      expect(resumed.stderr).toBe("");
      expect(JSON.parse(resumed.stdout).session_id).toBe(sessionId);
      expect(JSON.parse(resumed.stdout).output).toBe("PARTIAL_RECORD_RECOVERED");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.requests[1]!.body).not.toContain("partial-tail");

      const repaired = readFileSync(eventsPath, "utf8");
      expect(repaired.startsWith(committed)).toBe(true);
      expect(repaired).not.toContain("partial-tail");
      const files = readdirSync(sessionDir, { withFileTypes: true })
        .filter((entry) => entry.isFile())
        .map((entry) => entry.name)
        .sort();
      expect(files).toEqual([
        "events.jsonl",
        "permissions.json",
        "session.json",
        "session.lock",
        "usage-v2.json",
      ]);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);

  for (const partialNextRecord of [false, true]) {
    test(`writable resume truncates an unfinished turn with partial next record=${partialNextRecord}`, async () => {
      const fixture = createFixture("fx-session-unfinished-turn-");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("FIRST_TURN_SAVED"),
        fakeGatewayFinalText("UNFINISHED_TURN_RECOVERED"),
      ]);
      try {
        const sessionId = await createSavedSession(fixture, gateway);
        const eventsPath = join(
          fixture.home,
          ".fx",
          "sessions",
          sessionId,
          "events.jsonl",
        );
        const committed = readFileSync(eventsPath, "utf8");
        const lines = committed.trimEnd().split("\n");
        const last = JSON.parse(lines[lines.length - 1]!);
        appendFileSync(eventsPath, JSON.stringify({
          schema_version: 1,
          seq: last.seq + 1,
          timestamp_ms: Date.now(),
          event: {
            user: {
              text: "DANGLING_USER_MUST_NOT_REPLAY",
              images: [],
              work_id: null,
            },
          },
        }) + "\n");
        if (partialNextRecord) appendFileSync(eventsPath, '{"schema_version":1,"event":');

        const resumed = await continueSession(fixture, gateway, sessionId);
        expect(resumed.code).toBe(0);
        expect(resumed.stderr).toBe("");
        expect(JSON.parse(resumed.stdout).output).toBe("UNFINISHED_TURN_RECOVERED");
        expect(gateway.requests).toHaveLength(2);
        expect(gateway.requests[1]!.body).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
        expect(readFileSync(eventsPath, "utf8")).not.toContain(
          "DANGLING_USER_MUST_NOT_REPLAY",
        );
      } finally {
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    }, TIMEOUT);
  }

  test("committed-history corruption fails closed without rewriting JSONL", async () => {
    const fixture = createFixture("fx-session-middle-corruption-");
    const gateway = startFakeGateway([
      fakeGatewayFinalText("FIRST_TURN_SAVED"),
    ]);
    try {
      const sessionId = await createSavedSession(fixture, gateway);
      const eventsPath = join(
        fixture.home,
        ".fx",
        "sessions",
        sessionId,
        "events.jsonl",
      );
      const committed = readFileSync(eventsPath, "utf8");
      const corrupted = `[${committed.slice(1)}`;
      writeFileSync(eventsPath, corrupted, { mode: 0o600 });

      const detail = await runFx(
        ["session", "--id", sessionId, "--json"],
        {
          cwd: fixture.workspace,
          env: { HOME: fixture.home },
          timeoutMs: TIMEOUT,
        },
      );
      expect(detail.code).toBe(1);
      expect(detail.stderr).toBe("");
      expect(JSON.parse(detail.stdout)).toMatchObject({
        code: "SessionNotFound",
      });
      expect(readFileSync(eventsPath, "utf8")).toBe(corrupted);
      expect(gateway.requests).toHaveLength(1);
    } finally {
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  }, TIMEOUT);
});
