from __future__ import annotations

import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts import prepare_release_notes as notes

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BODY = "**fx keeps saved conversations available after a restart.**\n\n### Bug Fixes\n\n- Saved conversations now resume after a restart.\n"
CHANGELOG = f"# fx\n\n## 0.0.9\n\n<!-- release:start -->\n\n{BODY}\n<!-- release:end -->\n"
MAIN = "a" * 40
BRANCH = "b" * 40


def stream(result: dict, reason: str = "stop") -> str:
    events = [
        {"type": "text-delta", "delta": json.dumps(result)},
        {"type": "finish", "finishReason": {"unified": reason}},
    ]
    return "\n\n".join("data: " + json.dumps(event) for event in events) + "\n\n"


class ReleaseNotesTests(unittest.TestCase):
    def test_approved_009_entry_passes_without_rewriting(self) -> None:
        changelog = (REPO_ROOT / "CHANGELOG.md").read_text()
        body = changelog.split("## 0.0.9\n", 1)[1].split("\n## ", 1)[0]
        body = body.replace("<!-- release:start -->", "").replace("<!-- release:end -->", "")
        notes.validate_body(body)

    def test_format_rejects_labels_internal_details_and_missing_summary(self) -> None:
        for body in (
            BODY.replace("- Saved", "- **Sessions:** Saved"),
            BODY.replace("- Saved", "- **Sessions**: Saved"),
            BODY.replace("fx keeps", "Fx keeps"),
            BODY.replace("Saved conversations now resume after a restart.", "CI now publishes release artifacts."),
            BODY.replace("Saved conversations now resume after a restart.", "Fixed #123."),
            BODY.split("\n\n", 1)[1],
            BODY + "\n### Security\n",
            BODY + "\nContinuation outside a bullet.\n",
        ):
            with self.subTest(body=body), self.assertRaises(ValueError):
                notes.validate_body(body)

    def test_existing_edited_release_is_reused_without_regeneration(self) -> None:
        edited = CHANGELOG.replace("after a restart.", "after signing in again.")
        pr = dict(state="OPEN", headRefOid=BRANCH, labels=[{"name": "type: release"}])
        self.assertFalse(notes.branch_policy(MAIN, BRANCH, "0.0.9", "0.0.9", edited, pr))
        self.assertFalse(notes.branch_policy(MAIN, BRANCH, "0.0.9", "0.0.9", edited, None))

    def test_new_or_interrupted_bare_branch_can_be_prepared(self) -> None:
        self.assertTrue(notes.branch_policy(MAIN, None, "0.0.9", None, None, None))
        self.assertTrue(notes.branch_policy(MAIN, MAIN, "0.0.9", "0.0.8", None, None))

    def test_plan_reuses_existing_pr_and_never_requests_a_remote_write(self) -> None:
        with tempfile.TemporaryDirectory(prefix="release-plan-") as tmp:
            root = pathlib.Path(tmp)
            (root / "src").mkdir()
            (root / "src/main.zig").write_text('pub const version = "0.0.8";\n')
            pr = dict(number=42, state="OPEN", headRefOid=BRANCH, labels=[])
            responses = [MAIN, f"{BRANCH}\trefs/heads/prepare-v0.0.9",
                         'pub const version = "0.0.9";', CHANGELOG, json.dumps([pr])]
            with contextlib.chdir(root), mock.patch.object(notes, "command", side_effect=responses) as read, \
                    mock.patch.object(notes.subprocess, "run") as fetch:
                plan = notes.make_plan("patch")
            self.assertFalse(plan["prepare"])
            self.assertFalse(plan["create_branch"])
            self.assertEqual(42, plan["pr_number"])
            self.assertEqual(BRANCH, plan["expected_head"])
            self.assertEqual("main", read.call_args.args[read.call_args.args.index("--base") + 1])
            fetch.assert_called_once_with(["git", "fetch", "origin", "refs/heads/prepare-v0.0.9"], check=True)

    def test_branch_conflicts_and_closed_prs_preserve_existing_state(self) -> None:
        for branch_version, changelog, pr in (
            ("0.0.8", None, None),
            ("0.0.9", CHANGELOG, dict(state="CLOSED", headRefOid=BRANCH)),
            ("0.0.9", CHANGELOG, dict(state="MERGED", headRefOid=BRANCH)),
            ("0.0.9", CHANGELOG, dict(state="OPEN", headRefOid=MAIN)),
            ("0.0.9", CHANGELOG.replace("## 0.0.9", "## 0.0.8"), None),
            ("0.0.9", CHANGELOG, dict(state="OPEN", headRefOid=BRANCH, labels=[{"name": "type: bug"}])),
        ):
            with self.subTest(pr=pr), self.assertRaises(ValueError):
                notes.branch_policy(MAIN, BRANCH, "0.0.9", branch_version, changelog, pr)

    def test_complete_chunks_preserve_large_diff_and_non_src_changes(self) -> None:
        evidence = (
            "diff --git a/src/input.zig b/src/input.zig\n" + "+saved state λ\n" * 12_000
            + "diff --git a/sdk/browser.js b/sdk/browser.js\n+browser fix\n"
            + "diff --git a/README.md b/README.md\n+public command\n"
            + "diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml\n+internal check\n"
        )
        chunks = notes.split_evidence(evidence)
        self.assertGreater(len(chunks), 1)
        self.assertEqual(evidence, "".join(chunk["text"] for chunk in chunks))
        self.assertEqual("chunk-001", chunks[0]["id"])
        self.assertEqual("diff --git a/src/input.zig b/src/input.zig", chunks[1]["context"])
        self.assertIn("+public command", chunks[-1]["text"])
        for chunk in chunks:
            self.assertLessEqual(len(chunk["text"].encode()), notes.CHUNK_BYTES)

    def test_collection_uses_all_repository_files_and_preserves_last_line(self) -> None:
        diff = "diff --git a/sdk/node.js b/sdk/node.js\n+important trailing spaces  \n"
        with mock.patch.object(notes, "command", side_effect=["stat", "commits", diff]) as run:
            collected = notes.collect_evidence("v0.0.8", MAIN)
        self.assertTrue(collected.endswith(diff))
        self.assertEqual(("git", "diff", "--no-ext-diff", "--no-textconv", "--find-renames", f"v0.0.8..{MAIN}"),
                         run.call_args.args)
        self.assertEqual({"strip": False}, run.call_args.kwargs)

    def test_budget_failures_never_return_partial_evidence(self) -> None:
        with mock.patch.object(notes, "MAX_EVIDENCE_BYTES", 10):
            with self.assertRaisesRegex(ValueError, "no text was dropped"):
                notes.split_evidence("too much evidence\n")
        with self.assertRaisesRegex(ValueError, "no text was dropped"):
            notes.split_evidence("oversized single line", chunk_bytes=5)
        with mock.patch.object(notes, "MAX_CHUNKS", 1):
            with self.assertRaisesRegex(ValueError, "no text was dropped"):
                notes.split_evidence("one\ntwo\n", chunk_bytes=4)

    def test_stream_requires_normal_completion_even_with_valid_json(self) -> None:
        self.assertEqual({"value": 1}, notes.parse_stream(stream({"value": 1})))
        for response in (
            stream({"value": 1}, "length"),
            stream({"value": 1}, "error"),
            'data: {"type":"text-delta","delta":"{}"}\n\n',
            'data: {"type":"error","error":"failure"}\n\n',
            stream({}) + 'data: {"type":"text-delta","delta":"late"}\n\n',
        ):
            with self.subTest(response=response), self.assertRaises(ValueError):
                notes.parse_stream(response)

    def test_gateway_uses_kimi_k3_with_xhigh_reasoning(self) -> None:
        with tempfile.TemporaryDirectory(prefix="release-gateway-") as tmp:
            response = io.BytesIO(stream({"result": "complete"}).encode())
            with mock.patch.dict(notes.os.environ, {"AI_GATEWAY_API_KEY": "fixture-key"}), \
                    mock.patch.object(notes.urllib.request, "urlopen", return_value=response) as send:
                result = notes.gateway("policy", "evidence", pathlib.Path(tmp) / "response.json")
            self.assertEqual({"result": "complete"}, result)
            request = send.call_args.args[0]
            self.assertEqual("https://ai-gateway.vercel.sh/v4/ai/language-model", request.full_url)
            self.assertEqual("4", request.get_header("Ai-language-model-specification-version"))
            self.assertEqual("moonshotai/kimi-k3", request.get_header("Ai-language-model-id"))
            self.assertEqual("true", request.get_header("Ai-language-model-streaming"))
            payload = json.loads(request.data)
            self.assertEqual("xhigh", payload.get("reasoning"))
            self.assertEqual("system", payload["prompt"][0]["role"])
            self.assertEqual([{"type": "text", "text": "evidence"}], payload["prompt"][1]["content"])
            with mock.patch.object(notes, "MAX_REQUEST_BYTES", 1), \
                    mock.patch.object(notes.urllib.request, "urlopen") as send:
                with self.assertRaisesRegex(ValueError, "no input was dropped"):
                    notes.gateway("policy", "evidence", pathlib.Path(tmp) / "oversized.json")
                send.assert_not_called()

    def test_chunk_analysis_must_name_chunk_and_account_for_omissions(self) -> None:
        chunk = {"id": "chunk-001"}
        for analysis in (
            {"chunk_id": "other", "behaviors": []},
            {"chunk_id": "chunk-001", "behaviors": []},
            {"chunk_id": "chunk-001", "behaviors": [
                {"public": False, "description": "Internal change", "evidence": "ci.yml"}]},
        ):
            with self.subTest(analysis=analysis), self.assertRaises(ValueError):
                notes.checked_behaviors(chunk, analysis)
        self.assertEqual([], notes.checked_behaviors(
            chunk, {"chunk_id": "chunk-001", "behaviors": [], "omission_reason": "Commit research only"}))

    def test_synthesis_covers_every_behavior_and_keeps_internal_work_private(self) -> None:
        behaviors = [{"id": "public", "public": True}, {"id": "internal", "public": False}]
        result = dict(summary="fx keeps saved conversations available after a restart.",
                      items=[dict(section="Bug Fixes", text="Saved conversations now resume after a restart.",
                                  behavior_ids=["public"])],
                      omitted=[dict(behavior_id="internal", reason="CI-only change")])
        self.assertEqual(BODY, notes.render_notes(result, behaviors))
        invalid = json.loads(json.dumps(result))
        invalid["omitted"] = []
        with self.assertRaisesRegex(ValueError, "dropped"):
            notes.render_notes(invalid, behaviors)
        invalid["items"][0]["behavior_ids"].append("internal")
        with self.assertRaisesRegex(ValueError, "internal-only"):
            notes.render_notes(invalid, behaviors)
        invalid = json.loads(json.dumps(result))
        invalid["omitted"].append(invalid["omitted"][0])
        with self.assertRaisesRegex(ValueError, "duplicated"):
            notes.render_notes(invalid, behaviors)

    def test_draft_pipeline_accounts_for_all_chunks_without_network(self) -> None:
        evidence = "diff --git a/sdk/node.js b/sdk/node.js\n" + "+saved state\n" * 24_000
        requests = []

        def fake_gateway(system: str, user: str, output: pathlib.Path) -> dict:
            payload = json.loads(user)
            requests.append(payload)
            if "id" in payload:
                result = dict(chunk_id=payload["id"], behaviors=[dict(
                    description="Saved conversations resume", evidence="sdk/node.js",
                    public=True, omission_reason="")], omission_reason="")
            else:
                result = dict(summary="fx keeps saved conversations available after a restart.",
                              items=[dict(section="Bug Fixes", text="Saved conversations now resume after a restart.",
                                          behavior_ids=[row["id"] for row in payload["behaviors"]])],
                              omitted=[])
            output.write_text(json.dumps(result))
            return result

        with tempfile.TemporaryDirectory(prefix="release-draft-") as tmp:
            root = pathlib.Path(tmp)
            (root / "CHANGELOG.md").write_text(CHANGELOG)
            with contextlib.chdir(root), mock.patch.object(notes, "command", return_value="v0.0.8"), \
                    mock.patch.object(notes, "collect_evidence", return_value=evidence), \
                    mock.patch.object(notes, "gateway", side_effect=fake_gateway):
                notes.draft(dict(main_sha=MAIN, version="0.0.10"), root / "out")
            chunks = json.loads((root / "out/chunks.json").read_text())
            self.assertEqual(evidence, (root / "out/evidence.txt").read_text())
            self.assertEqual(len(chunks) + 1, len(requests))
            self.assertEqual(len(chunks), len(requests[-1]["behaviors"]))
            self.assertEqual(BODY, (root / "out/changelog-body.md").read_text())

    def test_apply_preserves_history_and_zon_and_refuses_second_write(self) -> None:
        with tempfile.TemporaryDirectory(prefix="release-apply-") as tmp:
            root = pathlib.Path(tmp)
            (root / "src").mkdir()
            (root / "src/main.zig").write_text('pub const version = "0.0.9";\n')
            (root / "README.md").write_text("curl installer | bash -s v0.0.9\n")
            (root / "CHANGELOG.md").write_text(CHANGELOG)
            (root / "build.zig.zon").write_bytes(b"unchanged placeholder")
            plan = dict(current="0.0.9", version="0.0.10")
            with contextlib.chdir(root):
                notes.apply_notes(plan, BODY)
                after = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
                self.assertEqual(BODY.strip(), notes.active_notes(
                    (root / "CHANGELOG.md").read_text(), "0.0.10"))
                self.assertIn("## 0.0.9", (root / "CHANGELOG.md").read_text())
                self.assertEqual(b"unchanged placeholder", (root / "build.zig.zon").read_bytes())
                with self.assertRaises(ValueError):
                    notes.apply_notes(plan, BODY.replace("restart", "login"))
                self.assertEqual(after, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})


if __name__ == "__main__":
    unittest.main()
