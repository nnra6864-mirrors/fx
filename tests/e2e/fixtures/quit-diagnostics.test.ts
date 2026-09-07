import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN } from "../../evals/eval-helpers";
import { TmuxSession } from "../tmux-helpers";

const output = process.env.FX_QUIT_DIAGNOSTICS_DIR;
if (!output) throw new Error("FX_QUIT_DIAGNOSTICS_DIR is required");
mkdirSync(output, { recursive: true, mode: 0o700 });

type Entry = {
  name: string;
  directory: string;
  trace?: string;
  processId?: number;
  paneId?: number;
  quitAt?: number;
  historyLimit?: number;
  errors: string[];
  observations: unknown[];
};

const entries = new Map<TmuxSession, Entry>();
function save() {
  writeFileSync(join(output!, "observations.json"), JSON.stringify([...entries.values()], null, 2), { mode: 0o600 });
}

function command(argv: string[]) {
  const result = Bun.spawnSync(argv, { timeout: 5000, stdout: "pipe", stderr: "pipe" });
  return { code: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() };
}

function processInfo(pid?: number) {
  if (!pid) return null;
  return command(["ps", "-p", String(pid), "-o", "pid=,ppid=,stat=,comm="]);
}

async function capture(session: TmuxSession, phase: string, sample: boolean) {
  const entry = entries.get(session);
  if (!entry) return;
  const target = entry.name + ":0.0";
  const pane = command(["tmux", "display-message", "-t", target, "-p", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}|#{remain-on-exit}|#{pid}"]);
  const process = processInfo(entry.processId);
  const observer = processInfo(entry.paneId);
  const exitPath = (session as unknown as { exitStatusPath: string }).exitStatusPath;
  const exitStatus = existsSync(exitPath) ? readFileSync(exitPath, "utf8").trim() : null;
  const observation: Record<string, unknown> = {
    phase,
    timestamp: Date.now(),
    sinceQuitMs: entry.quitAt === undefined ? null : Date.now() - entry.quitAt,
    sessionAlive: session.isAlive(),
    paneStatus: session.paneStatus(),
    pane,
    process,
    observer,
    recordedExitStatus: exitStatus,
  };
  entry.observations.push(observation);
  if (entry.trace && existsSync(entry.trace)) copyFileSync(entry.trace, join(entry.directory, phase + ".trace"));
  try {
    writeFileSync(join(entry.directory, phase + ".scrollback.txt"), await session.captureFullScrollback(), { mode: 0o600 });
  } catch (error) { entry.errors.push(String(error)); }
  save();
  if (sample) {
    if (entry.processId && process?.code === 0 && process.stdout.includes(FX_BIN)) {
      observation.processSample = command(["sample", String(entry.processId), "1", "10", "-file", join(entry.directory, "fx-sample.txt")]);
    }
    if (entry.paneId && observer?.code === 0) {
      observation.observerSample = command(["sample", String(entry.paneId), "1", "10", "-file", join(entry.directory, "observer-sample.txt")]);
    }
    const serverId = Number(pane.stdout.trim().split("|").at(-1));
    if (pane.code === 0 && Number.isSafeInteger(serverId) && serverId > 0) {
      observation.serverSample = command(["sample", String(serverId), "1", "10", "-file", join(entry.directory, "tmux-sample.txt")]);
    }
    save();
  }
}

const create = TmuxSession.create;
TmuxSession.create = async function (options) {
  const session = await create(options);
  const directory = join(output!, session.name);
  mkdirSync(directory, { mode: 0o700 });
  const entry: Entry = { name: session.name, directory, trace: options?.env?.FX_TRACE_LOG, errors: [], observations: [] };
  try {
    entry.paneId = session.panePid();
    entry.processId = session.processPid();
    entry.historyLimit = session.historyLimit();
  } catch (error) { entry.errors.push(String(error)); }
  entries.set(session, entry);
  save();
  return session;
};

const sendText = TmuxSession.prototype.sendText;
TmuxSession.prototype.sendText = async function (text) {
  if (text === "/quit") {
    const entry = entries.get(this);
    if (entry) entry.quitAt = Date.now();
  }
  return sendText.call(this, text);
};

const waitForSessionEnd = TmuxSession.prototype.waitForSessionEnd;
TmuxSession.prototype.waitForSessionEnd = async function (timeout) {
  try {
    const result = await waitForSessionEnd.call(this, timeout);
    await capture(this, "exited", false);
    return result;
  } catch (error) {
    await capture(this, "timeout", true);
    throw error;
  }
};

const kill = TmuxSession.prototype.kill;
TmuxSession.prototype.kill = async function () {
  await capture(this, "cleanup", false);
  return kill.call(this);
};

await import("../tui-render-stress.test.ts");
