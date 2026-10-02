// libfx/workflow: a libfx journal stored in a Workflow World, and the queue
// route that resumes a session after its process stopped.
//
// The session is a World run and each journal append is one `step_created`
// event in it, so the run's event log holds the session. The World is passed
// in by the app: this module imports nothing from `@workflow/*`.
//
//   const durable = workflow({ world, sessionId, createAgent });
//   const agent = await createAgent(durable);   // createFxAgent({ ...durable, ... })
//   export const POST = durable.handler;        // the queue calls this after a crash

import { FxFencedError } from "./fx-sdk.js";

const journalStep = "libfx.journal";
const payloadFormat = "libfx-journal-v1";
const defaultWorkflowName = "libfx";
const defaultWakeAfterSeconds = 300;
// The default queue topic prefix for workflow runs (`getQueueTopicPrefix`).
export const workflowQueuePrefix = "__wkf_workflow_";
// Event ids are `evnt_` followed by the slot, zero-padded to 26 digits.
const eventIdPattern = /^[a-z]+_(\d{26})$/;

export { FxFencedError };

function slotOf(event) {
  const match = eventIdPattern.exec(String(event?.eventId ?? ""));
  return match ? Number(match[1]) : null;
}

function journalBatch(event) {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== journalStep) return null;
  const input = event.eventData.input;
  if (input?.format !== payloadFormat || !Array.isArray(input.events) || input.events.length === 0) return null;
  return input.events;
}

// Whether a turn is open after `events`: progress or a tool intent opens one;
// a commit or a cleared turn closes it; compaction leaves it as it was.
function turnOpenAfter(open, events) {
  for (const event of events) {
    if (event.type === "turn_progress" || event.type === "tool_intent") open = true;
    else if (event.type === "turn_committed" || event.type === "turn_progress_cleared") open = false;
  }
  return open;
}

// Whether the journal holds follow-ups no turn has run: accepted, and never
// placed by a progress or withdrawn.
function holdsFollowUps(events) {
  const waiting = new Set();
  for (const event of events) {
    if (event.type === "input_accepted" && event.data?.kind === "follow_up") waiting.add(event.data.id);
    else if (event.type === "input_withdrawn") waiting.delete(event.data?.id);
    else if (event.type === "turn_progress") for (const id of event.inputs ?? []) waiting.delete(id);
  }
  return waiting.size > 0;
}

// The journal events a run holds. A batch counts only if it continues the
// events before it; a fenced writer's late batch repeats a seq and is skipped.
function journalEventsOf(events) {
  const journalEvents = [];
  for (const event of events) {
    const batch = journalBatch(event);
    if (batch && batch[0].seq === journalEvents.length + 1) journalEvents.push(...batch);
  }
  return journalEvents;
}

async function readRun(world, runId) {
  const events = [];
  let cursor;
  for (;;) {
    const page = await world.events.list({
      runId,
      pagination: { sortOrder: "asc", limit: 1000, ...(cursor ? { cursor } : {}) },
      resolveData: "all",
    });
    events.push(...page.data);
    if (!page.hasMore) break;
    cursor = page.cursor;
  }
  return events;
}

/**
 * Durability for `createFxAgent` over a World.
 *
 * - `world`: a Workflow World, such as `createWorld()` from
 *   `@workflow/world-vercel` or `@workflow/world-local`.
 * - `sessionId`: the session's run id. Omit it to create a new session; the
 *   returned `sessionId` is the new run's id once the agent has loaded.
 * - `createAgent(durable)`: builds the agent for `handler`, the same way the
 *   app does, for example `(durable) => createFxAgent({ apiKey, tools, ...durable })`.
 * - `wakeAfterSeconds`: how long an open turn may go without a write before
 *   the queue route takes it over. The owner writes a heartbeat while a turn
 *   is open, so this bounds silence, not turn length. Default 300.
 *
 * Returns `{ journal, sessionId, handler }`.
 */
export function workflow({
  world,
  sessionId,
  createAgent,
  workflowName = defaultWorkflowName,
  deploymentId = defaultWorkflowName,
  wakeAfterSeconds = defaultWakeAfterSeconds,
} = {}) {
  if (!world?.events || typeof world.events.create !== "function" || typeof world.events.list !== "function" || typeof world.queue !== "function") {
    throw new TypeError("workflow() needs a World with events.create(), events.list() and queue()");
  }
  if (sessionId !== undefined && (typeof sessionId !== "string" || sessionId.length === 0)) {
    throw new TypeError("sessionId must be a non-empty string");
  }
  if (createAgent !== undefined && typeof createAgent !== "function") {
    throw new TypeError("createAgent must be a function");
  }
  if (typeof wakeAfterSeconds !== "number" || !Number.isFinite(wakeAfterSeconds) || wakeAfterSeconds <= 0) {
    throw new TypeError("wakeAfterSeconds must be a positive number");
  }
  const options = { world, createAgent, workflowName, deploymentId, wakeAfterSeconds };
  const queueName = `${workflowQueuePrefix}${workflowName}`;
  const wakeAfterMs = wakeAfterSeconds * 1000;
  // At least 100 ms, so a short test timeout does not turn into a write loop.
  const heartbeatMs = Math.max(100, wakeAfterMs / 3);

  let runId = sessionId ?? null;
  // Slots this process has seen. Slots are dense, so this is the last one.
  let eventCount = 0;
  let previous = Promise.resolve();
  let fenced = null;
  // The seq the next journal batch starts at.
  let nextSeq = 1;
  let turnOpen = false;
  // Whether this process queued a wake for the open turn.
  let wakeQueued = false;
  let lastWriteAt = 0;
  let heartbeat = null;

  const queueWake = (delaySeconds) => world.queue(queueName, { runId }, { delaySeconds });

  function fence(message) {
    fenced = new FxFencedError(message);
    stopHeartbeat();
    return fenced;
  }

  // Writes one event at the slot after the last one this process has seen.
  // A World never refuses a write for a taken slot: it commits at the next
  // free one and reports what it skipped. When a skipped event is another
  // writer's batch starting at `seq`, that batch continues the journal and
  // this process's view is stale, so it stops writing; load skips whatever
  // it wrote after the other batch.
  async function commit(request, seq) {
    if (fenced) throw fenced;
    const result = await world.events.create(runId, request, { eventCount });
    lastWriteAt = Date.now();
    const slot = slotOf(result.event);
    const expected = eventCount + 1;
    eventCount = slot ?? expected;
    if (slot === expected) return;
    const skipped = Array.isArray(result.events) ? result.events : (await readRun(world, runId)).slice(expected - 1, eventCount - 1);
    if (skipped.some((event) => journalBatch(event)?.[0].seq === seq)) {
      throw fence(`another process wrote to session ${runId}; this one has stopped`);
    }
  }

  function serialize(task) {
    const done = previous.then(task);
    previous = done.catch(() => {});
    return done;
  }

  function startHeartbeat() {
    if (heartbeat) return;
    heartbeat = setInterval(() => {
      if (Date.now() - lastWriteAt < heartbeatMs) return;
      // A failed heartbeat is not retried here; the next one or the next
      // append writes again, and a fence stops both.
      serialize(() => (turnOpen && !fenced ? commit({ eventType: "noop", eventData: { libfx: "heartbeat" } }, nextSeq) : undefined)).catch(() => {});
    }, heartbeatMs);
    heartbeat.unref?.();
  }

  function stopHeartbeat() {
    if (!heartbeat) return;
    clearInterval(heartbeat);
    heartbeat = null;
  }

  async function write(batch) {
    const open = turnOpenAfter(turnOpen, batch);
    const wake = open && !wakeQueued;
    // A unique step id per write: a write that died partway can leave its id
    // taken in some Worlds, and must not block the write that replaces it.
    const step = commit({
      eventType: "step_created",
      correlationId: `fxj_${batch[0].seq}_${crypto.randomUUID()}`,
      eventData: { stepName: journalStep, input: { format: payloadFormat, events: batch } },
    }, batch[0].seq);
    // The wake rides alongside the turn's first write, so it costs no extra
    // round trip; without it no one resumes the turn if this process stops.
    await Promise.all([step, wake ? queueWake(wakeAfterSeconds) : undefined]);
    nextSeq = batch.at(-1).seq + 1;
    turnOpen = open;
    if (open) {
      wakeQueued = true;
      startHeartbeat();
    } else {
      wakeQueued = false;
      stopHeartbeat();
    }
  }

  const journal = {
    async load() {
      if (runId === null) {
        const created = await world.events.create(null, {
          eventType: "run_created",
          ...(world.specVersion === undefined ? {} : { specVersion: world.specVersion }),
          eventData: { deploymentId, workflowName, input: { format: payloadFormat } },
        });
        runId = created.run?.runId ?? created.event?.runId;
        if (typeof runId !== "string") throw new Error("the World did not return the new run's id");
        durable.sessionId = runId;
      }
      const events = await readRun(world, runId);
      eventCount = events.length;
      const journalEvents = journalEventsOf(events);
      nextSeq = journalEvents.length + 1;
      turnOpen = turnOpenAfter(false, journalEvents);
      return { events: journalEvents, sessionId: runId };
    },
    append(batch) {
      // Each write states the slot it expects, so writes go out in call order.
      return serialize(() => write(batch));
    },
  };

  const durable = {
    journal,
    sessionId: runId,
    /**
     * The queue route. Resumes the session a queue message names when its
     * open turn, or a follow-up it holds, has gone `wakeAfterSeconds`
     * without a write; checks again later while the owner is still writing;
     * does nothing once no work is left.
     */
    async handler(request) {
      if (!createAgent) throw new TypeError("workflow({ createAgent }) is required to handle queue messages");
      let message;
      try {
        message = await request.json();
      } catch {
        return new Response("invalid queue message", { status: 400 });
      }
      const target = message?.runId;
      if (typeof target !== "string") return new Response("queue message has no runId", { status: 400 });

      const events = await readRun(world, target);
      const journalEvents = journalEventsOf(events);
      if (!turnOpenAfter(false, journalEvents) && !holdsFollowUps(journalEvents)) return new Response(null, { status: 204 });
      const lastAt = Math.max(0, ...events.map((event) => new Date(event.createdAt).getTime()).filter(Number.isFinite));
      const silentMs = Date.now() - lastAt;
      if (silentMs < wakeAfterMs) {
        // The owner wrote recently and may still be running the turn.
        await world.queue(queueName, { runId: target }, { delaySeconds: Math.max(1, Math.ceil((wakeAfterMs - silentMs) / 1000)) });
        return new Response(null, { status: 204 });
      }

      const agent = await createAgent(workflow({ ...options, sessionId: target }));
      try {
        // The open turn first, then each follow-up the journal held.
        for (let turn = agent.resume(); turn; turn = agent.resume()) {
          for await (const _ of turn) {}
          await turn.result;
        }
      } finally {
        await agent.close();
      }
      return new Response(null, { status: 204 });
    },
  };
  return durable;
}
