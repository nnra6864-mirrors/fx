"""Compare immutable fx binaries while reading the same v2 histories."""

from __future__ import annotations

import argparse
import array
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import signal
import statistics
import subprocess
import tempfile
import termios
import threading
import time


CONTROL_SHA = "34f1ed14de47760b44d628ec2d5eb28055b9adf0"
CANDIDATE_SHA = "3cfd35837af1539dd33ae58f0df0071302508a80"
SEED = 7331111
BOOTSTRAPS = 3000


def crc_table() -> list[int]:
    table = []
    for value in range(256):
        for _ in range(8):
            value = (value >> 1) ^ (0x82F63B78 if value & 1 else 0)
        table.append(value)
    return table


CRC_TABLE = crc_table()


def crc32c(data: bytes) -> int:
    value = 0xFFFFFFFF
    for byte in data:
        value = CRC_TABLE[(value ^ byte) & 255] ^ (value >> 8)
    return value ^ 0xFFFFFFFF


def digest_strings(strings) -> str:
    digest = hashlib.sha256()
    for text in strings:
        data = text.encode()
        digest.update(len(data).to_bytes(8, "little"))
        digest.update(data)
    return digest.hexdigest()


def fixture(root: Path, turns: int) -> dict:
    home = root / "home"
    workspace = root / "workspace"
    home.mkdir(parents=True, mode=0o700)
    workspace.mkdir(mode=0o700)
    session_id = "replay_fixture"
    directory = home
    for component in (".fx", "sessions", "v2", session_id):
        directory /= component
        directory.mkdir(mode=0o700)
    log = directory / "log.jsonl"
    sequence = 0
    largest = 0
    compacted = 0
    kinds: dict[str, int] = {}
    users = []
    with log.open("wb") as output:
        def line(kind: str, **body):
            nonlocal sequence, largest
            sequence += 1
            payload = {"v": 1, "seq": sequence, "ts": 1700000000000 + sequence, "kind": kind, **body}
            raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))[:-1].encode()
            encoded = raw + f',"crc":"{crc32c(raw):08x}"}}\n'.encode()
            output.write(encoded)
            largest = max(largest, len(encoded))
            kinds[kind] = kinds.get(kind, 0) + 1

        def item(turn: int, item_type: str, data: dict):
            line("item", turn=turn, type=item_type, data=data)

        line("session_created", id=session_id, workspace=str(workspace), role="root", host="ask")
        line("set", key="prefs", value={"provider": "gateway", "model": "fixture/replay", "effort": "auto", "fast_mode": False})
        line("set", key="language", value="en")
        line("set", key="title", value="Replay comparison")
        for number in range(1, turns + 1):
            marker = f"REPLAY_USER_{number:06d}"
            text = marker + ("\nwide 漢字 and cafe\u0301\n" if number % 5 == 0 else " plain request")
            if number % 31 == 0:
                text += "\n" + "long wrapped content " * 420
            users.append(text)
            line("turn_started", turn=number)
            item(number, "user", {"text": text})
            item(number, "assistant", {"text": f"REPLAY_ANSWER_{number:06d}\n| field | value |\n| :--- | ---: |\n| row | {number} |"})
            if number % 7 == 0:
                item(number, "steering", {"text": f"steering {number}: retain the requested behavior"})
            if number % 13 == 0:
                item(number, "tool_running", {"call_id": f"replay_call_{number}", "tool_name": "shell", "arguments_json": '{"action":"run","command":"pwd"}'})
                line("turn_interrupted", turn=number, reason="crash")
            elif number % 9 == 0:
                item(number, "interruption", {"reason": "cancelled", "partial_text": f"partial answer {number}"})
                line("turn_interrupted", turn=number, reason="cancel")
            else:
                item(number, "turn_end", {"files": [], "turn_summary": None})
                line("turn_committed", turn=number)
            if number % 250 == 0:
                compacted += 1
                line("compacted", data={"summary": f"REPLAY_SUMMARY_{number}", "removed_turn_count": number - 25, "compaction_count": compacted, "keep_from_turn": number - 24})
        line("closed")
    log.chmod(0o600)
    raw = log.read_bytes()
    assert len(raw.splitlines()) == sequence
    assert all(crc32c(row.rsplit(b',"crc":', 1)[0]) == int(json.loads(row)["crc"], 16) for row in raw.splitlines())
    return {"home": str(home), "workspace": str(workspace), "id": session_id, "log": str(log), "turns": turns, "history_len": turns + compacted, "records": sequence, "bytes": len(raw), "largest_record": largest, "kinds": kinds, "sha256": hashlib.sha256(raw).hexdigest(), "users_sha256": digest_strings(users)}


def validate_output(output: bytes, case: dict) -> str:
    value = json.loads(output)
    assert value["kind"] == "session_detail" and value["id"] == case["id"]
    assert value["history_len"] == case["history_len"]
    assert len(value["history"]) == case["history_len"]
    users = [turn["user"]["text"] for turn in value["history"] if "user" in turn]
    assert len(users) == case["turns"]
    assert digest_strings(users) == case["users_sha256"], "missing, reordered, or changed user content"
    for number in (1, max(1, case["turns"] // 2), case["turns"]):
        assert f"REPLAY_USER_{number:06d}" in users[number - 1]
    return hashlib.sha256(output).hexdigest()


def environment(case: dict) -> dict[str, str]:
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    env.update({"HOME": case["home"], "FX_SESSIONS_V2": "1", "FX_DISABLE_KEYCHAIN": "1", "FX_AUTO_UPGRADE": "0", "FX_SOUND": "0", "FX_SKIP_ONBOARDING": "1", "NO_COLOR": "1", "AI_GATEWAY_API_KEY": "", "AI_GATEWAY_TEST_API_KEY": "", "VERCEL_OIDC_TOKEN": ""})
    return env


def invoke(binary: Path, case: dict, failure_dir: Path, label: str) -> dict:
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        start = time.perf_counter_ns()
        child = subprocess.Popen([str(binary), "session", case["id"], "--json"], cwd=case["workspace"], env=environment(case), stdout=stdout, stderr=stderr, start_new_session=True)
        timed_out = threading.Event()
        def timeout():
            timed_out.set()
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        timer = threading.Timer(60, timeout)
        timer.daemon = True
        timer.start()
        try:
            _, status, usage = os.wait4(child.pid, 0)
            end = time.perf_counter_ns()
            child.returncode = os.waitstatus_to_exitcode(status)
        finally:
            timer.cancel()
            timer.join()
        elapsed = (end - start) / 1e6
        stdout.seek(0)
        stderr.seek(0)
        output = stdout.read(128 * 1024 * 1024 + 1)
        errors = stderr.read(1024 * 1024 + 1)
        try:
            assert not timed_out.is_set(), "timeout"
            assert child.returncode == 0, f"exit {child.returncode}"
            assert not errors, "unexpected stderr"
            assert len(output) <= 128 * 1024 * 1024, "output limit exceeded"
            output_hash = validate_output(output, case)
        except Exception:
            failure_dir.mkdir(exist_ok=True)
            (failure_dir / f"{label}.stdout").write_bytes(output)
            (failure_dir / f"{label}.stderr").write_bytes(errors)
            raise
        return {"wall_ms": elapsed, "cpu_ms": 1000 * (usage.ru_utime + usage.ru_stime), "peak_rss_bytes": usage.ru_maxrss * (1 if platform.system() == "Darwin" else 1024), "output_sha256": output_hash, "exit_code": child.returncode}


def quantile(values: list[float], fraction: float) -> float:
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def memory_map(binary: Path, case: dict, output: Path, label: str) -> dict:
    """Hold a completed JSON response under pipe backpressure for vmmap."""
    read_fd, write_fd = os.pipe()
    child = None
    try:
        os.set_blocking(write_fd, False)
        filled = 0
        while True:
            try:
                filled += os.write(write_fd, b"x" * 131072)
            except BlockingIOError:
                break
        os.set_blocking(write_fd, True)
        assert filled >= 8192
        with tempfile.TemporaryFile() as stderr:
            child = subprocess.Popen([str(binary), "session", case["id"], "--json"], cwd=case["workspace"], env=environment(case), stdin=subprocess.DEVNULL, stdout=write_fd, stderr=stderr, start_new_session=True)
            os.close(write_fd)
            write_fd = -1
            os.read(read_fd, 4096)
            queued = array.array("i", [0])
            deadline = time.monotonic() + 10
            while True:
                fcntl.ioctl(read_fd, termios.FIONREAD, queued, True)
                if queued[0] >= filled:
                    break
                assert time.monotonic() < deadline, "response did not reach backpressure"
                time.sleep(.005)
            capture = subprocess.run(["/usr/bin/vmmap", "-wide", str(child.pid)], capture_output=True, timeout=30)
            (output / f"{label}.vmmap.txt").write_bytes(capture.stdout + capture.stderr)
            os.killpg(child.pid, signal.SIGKILL)
            _, status, usage = os.wait4(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(status)
            stderr.seek(0)
            (output / f"{label}.stderr").write_bytes(stderr.read())
            return {"capture_status": "captured" if capture.returncode == 0 else "not_run", "capture_exit": capture.returncode, "peak_rss_bytes": usage.ru_maxrss, "minor_faults": usage.ru_minflt, "major_faults": usage.ru_majflt, "stdout_pipe_bytes": filled, "stopping_condition": "complete response blocked on stdout"}
    finally:
        if child is not None and child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        os.close(read_fd)
        if write_fd != -1:
            os.close(write_fd)


def effect(pairs: list[dict], field: str, statistic) -> dict:
    control = [pair["control"][field] for pair in pairs]
    candidate = [pair["candidate"][field] for pair in pairs]
    base = statistic(control)
    head = statistic(candidate)
    rng = random.Random(SEED)
    deltas = []
    for _ in range(BOOTSTRAPS):
        selected = [rng.randrange(len(pairs)) for _ in pairs]
        deltas.append(statistic([candidate[i] for i in selected]) - statistic([control[i] for i in selected]))
    low, high = quantile(deltas, .025), quantile(deltas, .975)
    return {"control": base, "candidate": head, "delta": head - base, "percent": 100 * (head - base) / base if base else None, "ci95": [low, high], "resolved_increase": low > 0, "resolved_change": low > 0 or high < 0}


def comparison(pairs: list[dict], calibration: bool) -> dict:
    metrics = {"wall_p50_ms": effect(pairs, "wall_ms", statistics.median), "wall_p95_ms": effect(pairs, "wall_ms", lambda x: quantile(x, .95)), "cpu_mean_ms": effect(pairs, "cpu_ms", statistics.mean), "peak_rss_mean_bytes": effect(pairs, "peak_rss_bytes", statistics.mean)}
    passed = all(not value["resolved_change" if calibration else "resolved_increase"] for value in metrics.values())
    return {"passed": passed, "calibration": calibration, "metrics": metrics}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--control-manifest", type=Path)
    parser.add_argument("--candidate-manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sizes", default="64,1024,10000")
    parser.add_argument("--samples", type=int, default=50)
    parser.add_argument("--qualify-only", action="store_true")
    parser.add_argument("--memory-map", action="store_true")
    args = parser.parse_args()
    assert crc32c(b"123456789") == 0xE3069283
    assert args.samples >= 50
    args.control, args.candidate = args.control.resolve(strict=True), args.candidate.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    assert not any(args.output.iterdir()), "output directory must be empty"
    cases = [fixture(args.output / f"fixture-{turns}", turns) for turns in map(int, args.sizes.split(","))]
    binary_hashes = {"control": hashlib.sha256(args.control.read_bytes()).hexdigest(), "candidate": hashlib.sha256(args.candidate.read_bytes()).hexdigest()}
    sources = {"control": None, "candidate": None}
    for lane, manifest_path, expected_sha in (("control", args.control_manifest, CONTROL_SHA), ("candidate", args.candidate_manifest, CANDIDATE_SHA)):
        if manifest_path is None:
            assert args.qualify_only, "measured runs require qualified artifact manifests"
            continue
        manifest = json.loads(manifest_path.read_text())
        assert manifest["eligible"] is True and manifest["status"] == "passed"
        source = manifest["evidence"]["identity"]
        assert source["source_sha"] == expected_sha and source["target"] == "aarch64-macos"
        assert manifest["evidence"]["artifacts"]["candidate"]["sha256"] == binary_hashes[lane]
        sources[lane] = source
    if not args.qualify_only:
        for key in ("target", "update_channel", "zig_version", "llvm_version", "corpus_sha256"):
            assert sources["control"][key] == sources["candidate"][key], f"mismatched {key}"
    cpu = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip() if platform.system() == "Darwin" else platform.processor()
    mode = "harness-qualification" if args.qualify_only else "resident-memory-diagnostic" if args.memory_map else "paired-replay"
    identity = {"sources": sources, "binary_sha256": binary_hashes, "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "platform": platform.platform(), "architecture": platform.machine(), "cpu": cpu, "mode": mode, "cases": cases, "samples_per_lane_per_cohort": args.samples, "warmups": 3, "timeout_seconds": 60, "seed": SEED, "bootstraps": BOOTSTRAPS, "budget": "No statistically resolved latency, CPU, or peak-RSS increase; calibration must show no resolved change.", "source": "user requirement"}
    (args.output / "manifest.json").write_text(json.dumps(identity, indent=2))
    results = []
    qualifications = []
    for case in cases:
        outputs = []
        for lane, binary in (("control", args.control), ("candidate", args.candidate)):
            row = invoke(binary, case, args.output / "failures", f"qualify-{case['turns']}-{lane}")
            qualifications.append({"turns": case["turns"], "lane": lane, **row})
            outputs.append(row["output_sha256"])
            print(f"qualified {case['turns']} turns, {case['records']} records, {lane}", flush=True)
        assert outputs[0] == outputs[1], "binary outputs differ"
        (args.output / "qualifications.json").write_text(json.dumps(qualifications, indent=2))
        if args.memory_map:
            for index in range(3):
                order = (("control", args.control), ("candidate", args.candidate))
                if index % 2:
                    order = tuple(reversed(order))
                for lane, binary in order:
                    observation = memory_map(binary, case, args.output, f"{case['turns']}-{index}-{lane}")
                    results.append({"turns": case["turns"], "lane": lane, "index": index, **observation})
            assert hashlib.sha256(Path(case["log"]).read_bytes()).hexdigest() == case["sha256"]
            (args.output / "results.json").write_text(json.dumps({"status": "diagnostic_complete", "results": results}, indent=2))
            continue
        # An oracle that accepts a dropped turn cannot qualify the harness.
        with tempfile.TemporaryFile() as out:
            subprocess.run([str(args.control), "session", case["id"], "--json"], cwd=case["workspace"], env=environment(case), stdout=out, check=True)
            out.seek(0)
            bad = json.load(out)
            bad["history"].pop()
            try:
                validate_output(json.dumps(bad).encode(), case)
            except AssertionError:
                pass
            else:
                raise RuntimeError("dropped-turn mutation passed the oracle")
        assert hashlib.sha256(Path(case["log"]).read_bytes()).hexdigest() == case["sha256"], "read-only fixture changed"
        if args.qualify_only:
            continue
        for cohort, left, right, reverse in (("calibration", args.control, args.control, False), ("forward", args.control, args.candidate, False), ("reverse", args.control, args.candidate, True)):
            for _ in range(3):
                invoke(left, case, args.output / "failures", "warm-control")
                invoke(right, case, args.output / "failures", "warm-candidate")
            pairs = []
            raw_path = args.output / f"{case['turns']}-{cohort}.jsonl"
            with raw_path.open("w") as raw:
                for index in range(args.samples):
                    order = (("control", left), ("candidate", right))
                    if bool(index % 2) != reverse:
                        order = tuple(reversed(order))
                    pair = {lane: invoke(binary, case, args.output / "failures", f"{case['turns']}-{cohort}-{index}-{lane}") for lane, binary in order}
                    pairs.append(pair)
                    raw.write(json.dumps(pair) + "\n")
            result = {"turns": case["turns"], "cohort": cohort, "samples": len(pairs), **comparison(pairs, cohort == "calibration")}
            results.append(result)
            (args.output / "results.json").write_text(json.dumps({"status": "in_progress", "results": results}, indent=2))
            print(f"measured {case['turns']} turns, {cohort}, passed={result['passed']}", flush=True)
        assert hashlib.sha256(Path(case["log"]).read_bytes()).hexdigest() == case["sha256"], "read-only fixture changed"
    if args.memory_map:
        return
    passed = all(row["passed"] for row in results)
    (args.output / "results.json").write_text(json.dumps({"status": "qualified" if args.qualify_only else "passed" if passed else "failed", "results": results}, indent=2))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
