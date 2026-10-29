#!/usr/bin/env node
// Checks the sizes of the packages libfx publishes against
// package-size-budgets.json. The budgets start about 10% above the sizes they
// were set at; raise one only for a change that has to grow the package, and
// say so in the change.
//
//   node sdk/tests/test-package-size.mjs <libfx.tgz> --native-dir <dir> [--print]
//
// --print prints the measured sizes as budgets JSON instead of checking them.
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { nativeDirArgument, nativeTarballs } from "./native-package.mjs";

const tarball = resolve(process.argv[2] ?? "");
const nativeDir = nativeDirArgument();
assert.ok(nativeDir, "usage: test-package-size.mjs <libfx.tgz> --native-dir <dir> [--print]");
const budgets = JSON.parse(await readFile(new URL("./package-size-budgets.json", import.meta.url), "utf8"));

async function unpackedBytes(dir) {
  let total = 0;
  for (const entry of await readdir(dir, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) total += (await stat(join(entry.parentPath, entry.name))).size;
  }
  return total;
}

// The package as npm would unpack it, measured from the tarball itself.
async function measurePackage(path) {
  const dir = await mkdtemp(resolve(tmpdir(), "libfx-size-"));
  const untar = spawnSync("tar", ["-xzf", path, "-C", dir, "--strip-components=1"]);
  assert.equal(untar.status, 0, String(untar.stderr));
  return { dir, packed: (await stat(path)).size, unpacked: await unpackedBytes(dir) };
}

const measured = {};
const libfx = await measurePackage(tarball);
try {
  measured.libfx = { packed: libfx.packed, unpacked: libfx.unpacked };
  // The .wasm files as a deployment carries them, and the JavaScript every
  // agent loads, compressed as a browser downloads it.
  for (const file of ["fx-core.wasm", "fx-term.wasm"]) measured[file] = { bytes: (await stat(join(libfx.dir, file))).size };
  for (const file of ["engine.js", "wasm-runtime.js", "fx-sdk.js"]) {
    measured[file] = { gzip: gzipSync(await readFile(join(libfx.dir, file)), { level: 9 }).length };
  }
} finally {
  await rm(libfx.dir, { recursive: true, force: true });
}
for (const [name, path] of Object.entries(nativeTarballs(nativeDir))) {
  const platform = await measurePackage(path);
  measured[name] = { packed: platform.packed, unpacked: platform.unpacked };
  await rm(platform.dir, { recursive: true, force: true });
}

if (process.argv.includes("--print")) {
  console.log(JSON.stringify(measured, null, 2));
  process.exit(0);
}

const over = [];
for (const [name, sizes] of Object.entries(measured)) {
  const budget = budgets[name];
  assert.ok(budget, `package-size-budgets.json has no budget for ${name}`);
  for (const [metric, bytes] of Object.entries(sizes)) {
    assert.ok(budget[metric], `package-size-budgets.json has no ${metric} budget for ${name}`);
    const line = `${name} ${metric}: ${bytes} of ${budget[metric]} bytes (${Math.round(100 * bytes / budget[metric])}%)`;
    console.log(line);
    if (bytes > budget[metric]) over.push(line);
  }
}
assert.deepEqual(over, [], `over budget. A .wasm over its budget may have skipped sdk/scripts/optimize-wasm.mjs:\n${over.join("\n")}`);
console.log(`Package sizes passed: ${Object.keys(measured).length} files and packages within their budgets`);
