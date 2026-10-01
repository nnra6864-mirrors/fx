#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";
import { createFxAgent as createSharedAgent } from "../fx-sdk.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-images.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
// A real 1x1 PNG, plus a helper that builds a PNG-sniffable payload with an
// exact base64 length for limit probing (the kernel sniffs magic bytes only).
const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
// A different real 1x1 PNG, used as resizeImage output.
const resizedPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR42mNkAAAAAgAB4iG8MwAAAABJRU5ErkJggg==";
function pngWithEncodedLength(encodedLength) {
  assert.equal(encodedLength % 4, 0);
  const raw = Buffer.alloc((encodedLength / 4) * 3);
  Buffer.from(pngData, "base64").copy(raw);
  return raw.toString("base64");
}
const catalog = {
  object: "list",
  data: [
    { id: "sdk/vision-model", type: "language", tags: ["tool-use", "vision", "file-input"] },
    { id: "sdk/plain-model", type: "language" },
  ],
};

function mockGateway() {
  const state = { catalogFetches: 0, chatBodies: [] };
  const fetch = async (url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      state.catalogFetches += 1;
      return Response.json(catalog);
    }
    state.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch };
}

const baseOptions = {
  backend,
  apiKey: "sdk-images-test-key",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
};
const createAgent = (gateway, overrides) =>
  createFxAgent({ ...baseOptions, fetch: gateway.fetch, ...overrides });

async function runPrompt(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

function fileParts(body) {
  return body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
}

// An image block reaches an image-capable model as a v4 file part, alongside
// the text and its placeholder.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [
    { type: "text", text: "what is in this image?" },
    { type: "image", data: pngData, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 1);
  const body = gateway.state.chatBodies[0];
  const files = fileParts(body);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  const text = body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
  assert.match(text, /what is in this image\?/);
  await agent.close();
}

// Blob and File use their own media types and share the base64 wire format
// and the kernel's byte-sniffing path on both backends.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: { id: "sdk/vision-model" } });
  const file = new File([Buffer.from(pngData, "base64")], "image.png", { type: "image/png" });
  const result = await runPrompt(agent, [
    { type: "text", text: "describe this file" },
    { type: "image", data: file },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: pngData } },
  ]);
  await agent.close();
}

// Every input form reaches the core as raw bytes beside the ACP frame. The
// session/prompt frame carries only an attachment reference, and the model
// request carries the image once, as base64.
for (const [label, toData] of [
  ["base64", () => pngData],
  ["Uint8Array", (bytes) => new Uint8Array(bytes)],
  ["ArrayBuffer", (bytes) => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)],
  ["Buffer", (bytes) => Buffer.from(bytes)],
]) {
  const gateway = mockGateway();
  const frames = [];
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type === "acp.send" && event.message?.method === "session/prompt") frames.push(event.message);
    },
  });
  const result = await runPrompt(agent, [
    { type: "text", text: `describe this ${label} image` },
    { type: "image", data: toData(Buffer.from(pngData, "base64")), mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn", label);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: pngData } },
  ], label);
  const image = frames[0].params.prompt.find((block) => block.type === "image");
  assert.equal(image.data, undefined, `${label} image bytes must not ride the ACP frame`);
  assert.ok(Number.isInteger(image._meta?.fx?.attachment), `${label} image must reference an attachment`);
  assert.ok(!JSON.stringify(frames[0]).includes(pngData), `${label} frame must not contain base64 image data`);
  await agent.close();
}

// Caller-owned bytes are captured when prompt() returns, on the synchronous
// path and on the asynchronous resizeImage path alike.
for (const resizeImage of [undefined, (image) => image]) {
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model", ...(resizeImage ? { resizeImage } : {}) });
  const bytes = new Uint8Array(Buffer.from(pngData, "base64"));
  const turn = agent.prompt([{ type: "image", data: bytes, mimeType: "image/png" }]);
  bytes.fill(0);
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(fileParts(gateway.state.chatBodies[0])[0].data.data, pngData);
  await agent.close();
}

// resizeImage takes and returns raw bytes. Its output replaces the image, may
// change the media type, and the byte limits apply to it instead of the input.
{
  const gateway = mockGateway();
  const calls = [];
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    async resizeImage({ bytes, mimeType }) {
      calls.push({ type: bytes.constructor.name, length: bytes.byteLength, mimeType });
      return { bytes: Buffer.from(resizedPng, "base64"), mimeType: "image/png" };
    },
  });
  const oversized = new Uint8Array(5 * 1024 * 1024);
  Buffer.from(pngData, "base64").copy(oversized);
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const result = await runPrompt(agent, [
    { type: "text", text: "resize these first" },
    { type: "image", data: new Blob([oversized], { type: "image/png" }) },
    { type: "image", data: jpeg, mimeType: "image/jpeg" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(calls, [
    { type: "Uint8Array", length: oversized.byteLength, mimeType: "image/png" },
    { type: "Uint8Array", length: jpeg.byteLength, mimeType: "image/jpeg" },
  ]);
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
    { type: "file", mediaType: "image/png", data: { type: "data", data: resizedPng } },
    { type: "file", mediaType: "image/png", data: { type: "data", data: resizedPng } },
  ]);
  await agent.close();
}

// A failing or invalid resizeImage rejects only that turn, before the prompt
// is sent, and the agent stays usable.
{
  const gateway = mockGateway();
  let mode;
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    resizeImage({ bytes, mimeType }) {
      if (mode === "throw") throw new Error("resize failed");
      if (mode === "invalid") return { bytes: "not bytes", mimeType };
      if (mode === "oversized") return { bytes: new Uint8Array(4 * 1024 * 1024), mimeType };
      if (mode === "fill") return { bytes: new Uint8Array(3 * 1024 * 1024), mimeType };
      return { bytes, mimeType };
    },
  });
  const image = [{ type: "image", data: pngData, mimeType: "image/png" }];
  // Hook output within the image budgets still counts toward the frame bound.
  mode = "fill";
  await assert.rejects(
    agent.prompt([...image, ...image]).result,
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  mode = "throw";
  await assert.rejects(agent.prompt(image).result, /resize failed/);
  mode = "invalid";
  await assert.rejects(
    agent.prompt(image).result,
    (error) => error instanceof TypeError && /resizeImage must return/.test(error.message),
  );
  mode = "oversized";
  await assert.rejects(
    agent.prompt(image).result,
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.equal(gateway.state.chatBodies.length, 0);
  mode = "keep";
  assert.equal((await runPrompt(agent, image)).stopReason, "end_turn");
  await agent.close();
  await assert.rejects(createAgent(mockGateway(), { resizeImage: "nope" }), /resizeImage must be a function/);
}

// A resizeImage that reuses one output buffer for every image still sends
// each image with the bytes the hook returned for it.
{
  const gateway = mockGateway();
  const scratch = new Uint8Array(4096);
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    resizeImage({ bytes, mimeType }) {
      scratch.set(bytes);
      return { bytes: scratch.subarray(0, bytes.byteLength), mimeType };
    },
  });
  const result = await runPrompt(agent, [
    { type: "image", data: pngData, mimeType: "image/png" },
    { type: "image", data: resizedPng, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.deepEqual(fileParts(gateway.state.chatBodies[0]).map((part) => part.data.data), [pngData, resizedPng]);
  await agent.close();
}

// A pure-image prompt is valid; the placeholder keeps the turn non-empty.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [{ type: "image", data: pngData, mimeType: "image/png" }]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(fileParts(gateway.state.chatBodies[0]).length, 1);
  await agent.close();
}

// A model without advertised image input never receives the request; the turn
// fails with the explicit notice instead of crashing or sending the image.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/plain-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A model missing from the catalog cannot confirm image support: same
// explicit failure, still no image bytes on the wire.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/unlisted-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// Checkpoint/restore round-trips prompt images inside the checkpoint bound:
// the restored agent re-sends the same bytes on the next turn.
{
  const gateway = mockGateway();
  const first = await createAgent(gateway, { model: "sdk/vision-model" });
  const initial = await runPrompt(first, [
    { type: "text", text: "remember this image" },
    { type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) },
  ]);
  assert.equal(initial.stopReason, "end_turn");
  const checkpoint = await first.checkpoint();
  // More concurrent checkpoints than the native outbound table holds all succeed.
  const concurrent = await Promise.all(Array.from({ length: 16 }, () => first.checkpoint()));
  for (const bytes of concurrent) assert.deepEqual(Buffer.from(bytes), Buffer.from(checkpoint));
  await first.close();
  const stored = Buffer.from(checkpoint);
  assert.ok(stored.includes(Buffer.from(pngData, "base64")), "checkpoint must store the image bytes raw");
  assert.ok(!stored.includes(Buffer.from(pngData)), "checkpoint must not store the image as base64");

  const restored = await createAgent(gateway, { model: "sdk/vision-model", checkpoint });
  const followup = await runPrompt(restored, "describe it again");
  assert.equal(followup.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 2);
  const files = fileParts(gateway.state.chatBodies[1]);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  await restored.close();

  // Oversized and empty restore checkpoints fail with the same errors on both backends.
  await assert.rejects(
    createAgent(mockGateway(), { model: "sdk/vision-model", checkpoint: new Uint8Array(4 * 1024 * 1024 + 1) }),
    (error) => error.message === "libfx checkpoint is too large",
  );
  await assert.rejects(
    createAgent(mockGateway(), { model: "sdk/vision-model", checkpoint: new Uint8Array(0) }),
    (error) => error.message === "Invalid or non-fresh libfx checkpoint",
  );
}

// An idle checkpoint is sent before a later prompt, while one queued behind it
// follows the direct-call rule once that prompt is active.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  await runPrompt(agent, "first");
  const expected = Buffer.from(await agent.checkpoint());
  const idle = agent.checkpoint();
  const queued = agent.checkpoint();
  const turn = agent.prompt("second");
  assert.deepEqual(Buffer.from(await idle), expected);
  await assert.rejects(queued, /cannot checkpoint while a prompt is active/);
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  // The rejected call released its place, so the next call is idle again.
  const afterRejected = agent.checkpoint();
  const third = agent.prompt("third");
  assert.ok((await afterRejected).byteLength > 0);
  for await (const _ of third) {}
  await agent.close();
}

// A checkpoint requested from an event handler while another checkpoint's
// request is being sent waits for it instead of running beside it.
{
  const gateway = mockGateway();
  const nested = [];
  let agent;
  agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type === "acp.send" && event.message.method === "libfx/checkpoint" && nested.length < 8) {
        nested.push(agent.checkpoint());
      }
    },
  });
  await runPrompt(agent, "first");
  const expected = Buffer.from(await agent.checkpoint());
  for (let settled = -1; settled !== nested.length;) {
    settled = nested.length;
    await Promise.all(nested);
  }
  assert.equal(nested.length, 8);
  for (const bytes of await Promise.all(nested)) assert.deepEqual(Buffer.from(bytes), expected);
  await agent.close();
}

// SDK-side limits reject synchronously with typed errors naming the bound,
// before any runtime or network work.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });

  assert.throws(
    () => agent.prompt([{ type: "image", data: "", mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: pngData }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: 42, mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );

  assert.throws(
    () => agent.prompt([{ type: "image", data: new Blob(["untyped"]) }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Blob(["bytes"], { type: "image/png" }), mimeType: "image/jpeg" }]),
    (error) => error instanceof TypeError && /disagrees with Blob.type/.test(error.message),
  );
  let readOversized = false;
  class OversizedBlob extends Blob {
    get size() { return 1; }
    async arrayBuffer() { readOversized = true; return super.arrayBuffer(); }
  }
  assert.throws(
    () => agent.prompt([{ type: "image", data: new OversizedBlob([Buffer.alloc(4 * 1024 * 1024)], { type: "image/png" }) }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.equal(readOversized, false);
  const budgetBlob = new Blob([Buffer.alloc(3.5 * 1024 * 1024)], { type: "image/png" });
  assert.throws(
    () => agent.prompt(Array.from({ length: 2 }, () => ({ type: "image", data: budgetBlob }))),
    (error) => error instanceof RangeError && /prompt images exceed/.test(error.message),
  );
  // Raw bytes follow the same raw-byte budgets as Blob and base64 input.
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Uint8Array(4 * 1024 * 1024), mimeType: "image/png" }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: new Uint8Array(0), mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data, bytes, or a Blob/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: Buffer.from(pngData, "base64") }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );

  const overSized = pngWithEncodedLength(5 * 1024 * 1024 + 4);
  assert.throws(
    () => agent.prompt([{ type: "image", data: overSized, mimeType: "image/png" }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );

  const nine = Array.from({ length: 9 }, () => ({ type: "image", data: pngData, mimeType: "image/png" }));
  assert.throws(
    () => agent.prompt(nine),
    (error) => error instanceof RangeError && /more than 8 images/.test(error.message),
  );

  const half = pngWithEncodedLength(Math.floor(4.25 * 1024 * 1024));
  assert.throws(
    () => agent.prompt([
      { type: "image", data: half, mimeType: "image/png" },
      { type: "image", data: half, mimeType: "image/png" },
    ]),
    (error) => error instanceof RangeError && /prompt images exceed/.test(error.message),
  );

  // The model request carries images base64 encoded, so text and encoded
  // images share the 8 MiB frame bound on both backends. Exactly 8 MiB of
  // encoded image data passes the image budgets but not that bound once text
  // and the envelope are added, as base64 or as raw bytes.
  const quarter = pngWithEncodedLength(4 * 1024 * 1024);
  for (const data of [quarter, Buffer.from(quarter, "base64")]) {
    assert.throws(
      () => agent.prompt([
        { type: "text", text: "boundary" },
        { type: "image", data, mimeType: "image/png" },
        { type: "image", data, mimeType: "image/png" },
      ]),
      (error) => error instanceof RangeError && /frame limit/.test(error.message),
    );
  }
  assert.throws(
    () => agent.prompt("x".repeat(9 * 1024 * 1024)),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  let readMixed = false;
  class UnreadBlob extends Blob {
    arrayBuffer() { readMixed = true; return new Promise(() => {}); }
  }
  assert.throws(
    () => agent.prompt([
      { type: "text", text: "x".repeat(9 * 1024 * 1024) },
      { type: "image", data: new UnreadBlob(["bytes"], { type: "image/png" }) },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  assert.equal(readMixed, false);

  // Two Blobs that fill the image budget exactly also fill the frame bound
  // once encoded, so they fail before any Blob read.
  const boundaryBlob = new Blob([Buffer.alloc(3 * 1024 * 1024)], { type: "image/png" });
  assert.throws(
    () => agent.prompt([
      { type: "image", data: boundaryBlob },
      { type: "image", data: boundaryBlob },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );

  class LyingBlob extends Blob {
    get size() { return 1; }
    async arrayBuffer() { return new ArrayBuffer(4 * 1024 * 1024); }
  }
  const actualOverflow = agent.prompt([{ type: "image", data: new LyingBlob(["x"], { type: "image/png" }) }]);
  await assert.rejects(actualOverflow.result, (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message));

  assert.equal(gateway.state.catalogFetches, 0);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// The SDK decodes base64 itself, so non-canonical base64 throws before the
// turn starts. Kernel-side content validation stays authoritative: a sniffed
// media type that contradicts the declaration fails the turn with a typed error
// rather than reaching the model.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  for (const data of ["aGVsbG8", "aGVsbG9=", "aGVs\nbG8=", "aGVsbG8*"]) {
    assert.throws(
      () => agent.prompt([{ type: "image", data, mimeType: "image/png" }]),
      (error) => error instanceof TypeError && /requires canonical base64 data/.test(error.message),
    );
  }
  const jpegBytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");
  const mismatch = agent.prompt([{ type: "image", data: jpegBytes, mimeType: "image/png" }]);
  await assert.rejects(mismatch.result, /Invalid image prompt block/);
  const blobMismatch = agent.prompt([
    { type: "image", data: new Blob([Buffer.from(jpegBytes, "base64")], { type: "image/png" }) },
  ]);
  await assert.rejects(blobMismatch.result, /Invalid image prompt block/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A Blob read failure rejects only that turn and does not send a partial frame.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class BrokenBlob extends Blob {
    async arrayBuffer() { throw new Error("read failed"); }
  }
  const turn = agent.prompt([{ type: "image", data: new BrokenBlob(["bytes"], { type: "image/png" }) }]);
  await assert.rejects(turn.result, /read failed/);
  class CancelledBlob extends Blob {
    async arrayBuffer() { throw new Error("Cancelled"); }
  }
  const failedRead = agent.prompt([{ type: "image", data: new CancelledBlob(["bytes"], { type: "image/png" }) }]);
  await assert.rejects(failedRead.result, (error) => error.message === "Cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "retry with text")).stopReason, "end_turn");
  await agent.close();
}

// Steering during a Blob read waits for the prompt to reach the core on both
// backends instead of racing ahead of the initial session/prompt.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let finishRead;
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["x"], { type: "image/png" }) }]);
  const steering = turn.steer("focus on the image");
  await Promise.resolve();
  assert.equal(gateway.state.chatBodies.length, 0);
  finishRead(Buffer.from(pngData, "base64"));
  await steering;
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.ok(gateway.state.chatBodies.length >= 1);
  await agent.close();
}

// Cancel or close while Blob.arrayBuffer() is pending: settle promptly, do not
// send a late prompt, and leave the agent available for the next turn.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let finishRead;
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const blob = new SlowBlob([Buffer.from(pngData, "base64")], { type: "image/png" });
  const turn = agent.prompt([{ type: "image", data: blob }]);
  await Promise.resolve();
  const steering = turn.steer("pending guidance");
  turn.cancel();
  await assert.rejects(steering, /no prompt is running/);
  assert.equal((await turn.result).stopReason, "cancelled");
  finishRead(Buffer.from(pngData, "base64"));
  await new Promise((resolveTick) => setImmediate(resolveTick));
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "still usable")).stopReason, "end_turn");
  await agent.close();
}

{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise(() => {}); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
  await agent.close();
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
}

// A Blob can abort the signal synchronously from arrayBuffer(). The turn must
// still settle even when the read promise never resolves.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const controller = new AbortController();
  class AbortingBlob extends Blob {
    arrayBuffer() {
      controller.abort();
      return new Promise(() => {});
    }
  }
  const turn = agent.prompt([
    { type: "image", data: new AbortingBlob(["bytes"], { type: "image/png" }) },
  ], { signal: controller.signal });
  let timer;
  try {
    const result = await Promise.race([
      turn.result,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Blob abort did not settle")), 1500); }),
    ]);
    assert.equal(result.stopReason, "cancelled");
  } finally {
    clearTimeout(timer);
  }
  assert.equal(gateway.state.chatBodies.length, 0);
  assert.equal((await runPrompt(agent, "usable after abort")).stopReason, "end_turn");
  await agent.close();
}

// Closing from arrayBuffer() must find an initialized turn result and release
// the runtime rather than rejecting before it can close stdin.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  let closing;
  class ClosingBlob extends Blob {
    arrayBuffer() {
      closing = agent.close();
      return new Promise(() => {});
    }
  }
  const turn = agent.prompt([{ type: "image", data: new ClosingBlob(["bytes"], { type: "image/png" }) }]);
  await Promise.resolve();
  assert.ok(closing);
  let timer;
  try {
    await Promise.race([
      closing,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("reentrant close did not settle")), 1500); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(gateway.state.chatBodies.length, 0);
}

// A core exit before or just after Blob bytes arrive rejects the turn and
// iterator without submitting a prompt or reporting user cancellation.
for (const timing of ["during-read", "after-read"]) {
  let finishRuntime;
  let finishRead;
  let onLine;
  const sentMethods = [];
  const runtime = {
    exited: new Promise((resolveExit) => { finishRuntime = resolveExit; }),
    setLineHandler(handler) { onLine = handler; },
    write(line) {
      const request = JSON.parse(line);
      sentMethods.push(request.method);
      if (request.method === "initialize" || request.method === "libfx/new") {
        queueMicrotask(() => onLine({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "libfx/new" ? { sessionId: "image-exit-test" } : {},
        }));
      }
    },
    abortHostEffects() {},
    closeStdin() { finishRuntime(0); },
  };
  const controller = new AbortController();
  const agent = await createSharedAgent({
    apiKey: "image-exit-test-key",
    runtimeFactory: async () => runtime,
    onEvent(event) {
      if (event.type === "runtime.exit" && timing === "during-read") controller.abort();
    },
  });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }], { signal: controller.signal });
  const settled = Promise.all([
    assert.rejects(turn.result, /fx-core exited with code 1/),
    assert.rejects(turn[Symbol.asyncIterator]().next(), /fx-core exited with code 1/),
  ]);
  let timer;
  try {
    await Promise.resolve();
    if (timing === "after-read") finishRead(Buffer.from(pngData, "base64"));
    finishRuntime(1);
    await Promise.race([
      settled,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`core exit ${timing} did not settle Blob turn`)), 1500); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
  assert.equal(sentMethods.includes("session/prompt"), false);
  assert.equal(sentMethods.includes("session/cancel"), false);
  await agent.close();
}

// Queued steering must fail if the prompt write throws or the core exits as
// it accepts the write; neither case may deliver guidance to a dead turn.
for (const failure of ["write", "exit"]) {
  let finishRuntime;
  let onLine;
  let finishRead;
  const sentMethods = [];
  const runtime = {
    exited: new Promise((resolveExit) => { finishRuntime = resolveExit; }),
    setLineHandler(handler) { onLine = handler; },
    write(line) {
      const request = JSON.parse(line);
      sentMethods.push(request.method);
      if (request.method === "session/prompt") {
        if (failure === "write") throw new Error("prompt write failed");
        finishRuntime(1);
        return;
      }
      if (request.method === "initialize" || request.method === "libfx/new") {
        queueMicrotask(() => onLine({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "libfx/new" ? { sessionId: "image-write-test" } : {},
        }));
      }
    },
    steer(text) { sentMethods.push(`steer:${text}`); },
    writeAttachment(id) { sentMethods.push(`attachment:${id}`); },
    discardAttachments() {},
    abortHostEffects() {},
    closeStdin() { finishRuntime(0); },
  };
  const agent = await createSharedAgent({ apiKey: "image-write-test-key", runtimeFactory: async () => runtime });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise((resolveRead) => { finishRead = resolveRead; }); }
  }
  const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
  const steering = turn.steer("queued guidance");
  await Promise.resolve();
  finishRead(Buffer.from(pngData, "base64"));
  const expectedError = failure === "write" ? /prompt write failed/ : /fx-core exited with code 1/;
  await assert.rejects(turn.result, expectedError);
  await assert.rejects(steering, expectedError);
  assert.equal(sentMethods.includes("steer:queued guidance"), false);
  await agent.close();
}

// Pre-prompt steering has the same count and byte limits as the core queue.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  class SlowBlob extends Blob {
    arrayBuffer() { return new Promise(() => {}); }
  }
  for (const [payload, count] of [["x", 64], ["x".repeat(64 * 1024), 16]]) {
    const turn = agent.prompt([{ type: "image", data: new SlowBlob(["bytes"], { type: "image/png" }) }]);
    const queued = Array.from({ length: count }, () => turn.steer(payload).catch((error) => error));
    await assert.rejects(turn.steer(payload), /steering queue is full/);
    turn.cancel();
    const rejected = await Promise.all(queued);
    assert.ok(rejected.every((error) => error instanceof Error && /no prompt is running/.test(error.message)));
    assert.equal((await turn.result).stopReason, "cancelled");
  }
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A pre-aborted Blob prompt must reject steering immediately.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const controller = new AbortController();
  controller.abort();
  const turn = agent.prompt([
    { type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) },
  ], { signal: controller.signal });
  await assert.rejects(turn.steer("late guidance"), /no prompt is running/);
  assert.equal((await turn.result).stopReason, "cancelled");
  await agent.close();
}

// Cancellation from the send event must not let a late prompt through after
// its session/cancel notification.
{
  const gateway = mockGateway();
  let turn;
  let promptSendEvents = 0;
  const agent = await createAgent(gateway, {
    model: "sdk/vision-model",
    onEvent(event) {
      if (event.type !== "acp.send" || event.message?.method !== "session/prompt") return;
      promptSendEvents++;
      turn.cancel();
    },
  });
  turn = agent.prompt([{ type: "image", data: new Blob([Buffer.from(pngData, "base64")], { type: "image/png" }) }]);
  assert.equal((await turn.result).stopReason, "cancelled");
  assert.equal(promptSendEvents, 1);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

console.log(`${backend} agent image prompts passed`);
