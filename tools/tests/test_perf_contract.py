import json
import copy
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKLOADS = ROOT / "docs" / "performance" / "workloads"
EXPECTED_SCENARIOS = {
    "boot_registration",
    "idle_station",
    "localized_canister_breach",
    "corridor_pressure_breach",
    "plasma_reaction_storm",
    "turf_heat_sparse",
    "turf_heat_dense",
    "atmos_machinery_dense",
    "callback_consumer_throttled",
    "synthetic_core_matrix",
    "runtime_isolation",
}


class PerformanceContractTests(unittest.TestCase):
    def test_ipc_benchmark_separates_transport_and_service_cases(self):
        source = (
            ROOT / "crates" / "dogmos-perf" / "benches" / "ipc_round_trip.rs"
        ).read_text(encoding="utf-8")
        self.assertIn('name: "transport_scalar_getter"', source)
        self.assertIn("fn prepare_service_world(", source)
        self.assertIn("FrontierCommit", source)
        self.assertIn("next_stage_epoch", source)

        runner = (ROOT / "tools" / "benchmark_ipc.ps1").read_text(encoding="utf-8")
        self.assertIn('ipc-round-trip-$run.status.json', runner)
        self.assertIn("$successfulStatusRecords.Count -ne $Repetitions", runner)

    def test_workload_corpus_is_complete_and_reproducible(self):
        documents = {}
        for path in WORKLOADS.glob("*.json"):
            document = json.loads(path.read_text(encoding="utf-8"))
            documents[document["id"]] = document
            self.assertEqual(document["schema_version"], 1)
            self.assertIsInstance(document["seed"], int)
            self.assertGreater(document["duration_seconds"], 0)
            self.assertTrue(document["map"])
            self.assertTrue(document["expected_markers"])
            self.assertTrue(document["correctness_assertions"])
        self.assertEqual(set(documents), EXPECTED_SCENARIOS)
        matrix = documents["synthetic_core_matrix"]
        self.assertEqual(matrix["turf_counts"], [1000, 10000, 100000, 650250])
        self.assertEqual(matrix["gas_counts"], [4, 8, 9, 20])
        self.assertEqual(matrix["active_percentages"], [0, 1, 10, 100])
        self.assertEqual(matrix["topologies"], ["corridor", "grid", "multiz"])

    def test_workload_validator_accepts_corpus_and_emits_identity_hashes(self):
        script = ROOT / "tools" / "perf" / "Invoke-DogmosWorkload.ps1"
        completed = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-File",
                str(script),
                "-ValidateOnly",
                "-WorkloadDirectory",
                str(WORKLOADS),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        output = json.loads(completed.stdout)
        self.assertEqual(len(output), len(EXPECTED_SCENARIOS))
        self.assertTrue(all(len(item["scenario_sha256"]) == 64 for item in output))

    def test_comparison_rejects_mismatched_environment_identity(self):
        script = ROOT / "tools" / "perf" / "Compare-DogmosPerformance.ps1"
        completed = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-File",
                str(script),
                "-SelfTestIdentityMismatch",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertFalse(result["comparable"])
        self.assertIn("map", result["mismatches"])
        self.assertIn("scenario_sha256", result["mismatches"])

    def test_process_sampler_keeps_exact_pids_and_memory_roles_separate(self):
        script = ROOT / "tools" / "perf" / "Measure-DogmosProcesses.ps1"
        dreamdaemon = subprocess.Popen(
            ["powershell", "-NoProfile", "-Command", "Start-Sleep -Seconds 10"]
        )
        server = subprocess.Popen(
            ["powershell", "-NoProfile", "-Command", "Start-Sleep -Seconds 10"]
        )
        try:
            with tempfile.TemporaryDirectory() as output:
                completed = subprocess.run(
                    [
                        "powershell",
                        "-NoProfile",
                        "-File",
                        str(script),
                        "-DreamDaemonPid",
                        str(dreamdaemon.pid),
                        "-ServerPid",
                        str(server.pid),
                        "-OutputDirectory",
                        output,
                        "-DurationSeconds",
                        "0.7",
                        "-SampleIntervalMilliseconds",
                        "100",
                    ],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
                result = json.loads(completed.stdout)
                self.assertTrue(result["server_memory_is_separate"])
                self.assertNotIn("combined_memory", json.dumps(result))
                self.assertEqual(result["roles"]["dreamdaemon"]["pid"], dreamdaemon.pid)
                self.assertEqual(result["roles"]["server"]["pid"], server.pid)
                samples = Path(result["samples_path"]).read_text(encoding="utf-8-sig")
                self.assertIn("dreamdaemon", samples)
                self.assertIn("server", samples)
                self.assertIn("private_bytes", samples)
                self.assertIn("virtual_bytes", samples)
                self.assertIn("cpu_total_ticks", samples)
        finally:
            dreamdaemon.terminate()
            server.terminate()
            dreamdaemon.wait(timeout=5)
            server.wait(timeout=5)

    def test_comparison_enforces_dreamdaemon_and_tick_budgets_only(self):
        script = ROOT / "tools" / "perf" / "Compare-DogmosPerformance.ps1"
        identity = {
            "map": "MetaStation.dmm",
            "seed": 7,
            "revision": "same-controlled-revision",
            "features": ["default"],
            "byond_version": "516.1685",
            "duration_seconds": 60,
            "scenario_sha256": "a" * 64,
        }
        baseline = {
            "identity": identity,
            "summary": {
                "dreamdaemon_private_bytes": 1000,
                "server_private_bytes": 1,
                "server_tick_p95_ns": 100,
                "server_tick_p99_ns": 100,
            },
        }
        current = {
            "identity": identity,
            "summary": {
                "dreamdaemon_private_bytes": 250,
                "server_private_bytes": 1000000,
                "server_tick_p95_ns": 104,
                "server_tick_p99_ns": 109,
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            baseline_path = Path(directory) / "baseline.json"
            current_path = Path(directory) / "current.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            current_path.write_text(json.dumps(current), encoding="utf-8")
            completed = subprocess.run(
                [
                    "powershell",
                    "-NoProfile",
                    "-File",
                    str(script),
                    "-BaselinePath",
                    str(baseline_path),
                    "-CurrentPath",
                    str(current_path),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        result = json.loads(completed.stdout)
        self.assertTrue(result["acceptance_passed"])
        self.assertTrue(result["gates"]["dreamdaemon_private_bytes"]["passed"])
        self.assertEqual(result["gates"]["dreamdaemon_private_bytes"]["reduction_percent"], 75)
        self.assertEqual(result["server_private_bytes_delta_percent"], 99999900)
        self.assertNotIn("server_private_bytes", result["gates"])


def runtime_report(cohort):
    """Literal controlled reports: observations are synthetic test inputs only."""
    metrics = {
        "game_tick_ms": [10, 11, 12],
        "ssair_main_thread_ms": [2, 3, 4],
        "rpc_wait_ms": [1, 2, 3],
        "native_prepare_ms": None,
        "native_commit_ms": None,
        "job_age_ms": None,
        "conflicts": None,
        "cycle_age_ms": [100, 100, 100],
        "callback_age_ms": [0, 0, 0],
        "callbacks_pending": [0, 0, 0],
        "completed_cycles": 100,
    }
    return {
        "schema_version": 2,
        "kind": "runtime_isolation",
        "cohort": cohort,
        "mode": "synchronous",
        "identity": {
            "map": "_maps/map_files/MetaStation/MetaStation.dmm",
            "map_sha256": "a" * 64,
            "seed": 29051994,
            "features": ["default"],
            "byond_version": "516.1687",
            "duration_seconds": 300,
            "scenario_sha256": "b" * 64,
            "command_sequence_sha256": "c" * 64,
            "settings": {"atmos_wait_seconds": 0.5, "fdm_steps": 1},
        },
        "build": {
            "game_revision": "d" * 40,
            "game_dmb_sha256": "4" * 64,
            "native_revision": "e" * 40,
            "shim_sha256": "f" * 64,
            "service_sha256": "1" * 64,
            "bindings_sha256": "2" * 64,
            "contract_sha256": "3" * 64,
        },
        "runs": [
            {
                "run_id": f"{cohort}-{index}",
                "pair_id": str(index),
                "contaminated": False,
                "metrics": copy.deepcopy(metrics),
                "not_applicable": {
                    name: "No autonomous job in synchronous mode."
                    for name in ("native_prepare_ms", "native_commit_ms", "job_age_ms", "conflicts")
                },
                "equivalence": {"state_sha256": "4" * 64, "events": ["open", "move"]},
                "processes": {
                    role: [{"elapsed_ms": 0, "private_bytes": 100, "working_set_bytes": 100,
                            "virtual_bytes": 200, "cpu_total_seconds": 1},
                           {"elapsed_ms": 300000, "private_bytes": 100, "working_set_bytes": 100,
                            "virtual_bytes": 200, "cpu_total_seconds": 2}]
                    for role in ("dreamdaemon", "dogmosd")
                },
            }
            for index in range(3)
        ],
    }


class RuntimeIsolationContractTests(unittest.TestCase):
    def test_runtime_phase_validation_rejects_gaps_and_unbound_run_preparation(self):
        script = ROOT / "tools/perf/Invoke-DogmosWorkload.ps1"
        source = json.loads((WORKLOADS / "runtime-isolation.json").read_text(encoding="utf-8"))
        for case in ("gap", "order", "duration", "unbound_run"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                document = copy.deepcopy(source)
                if case == "gap": document["phases"][1]["start_seconds"] = 61
                elif case == "order": document["phases"].reverse()
                elif case == "duration": document["duration_seconds"] = 299
                path = Path(directory) / "runtime.json"
                path.write_text(json.dumps(document), encoding="utf-8")
                output = Path(directory) / "prepared"
                arguments = (["-WorkloadPath", str(path), "-OutputDirectory", str(output),
                              "-Revision", "e" * 40] if case == "unbound_run"
                             else ["-ValidateOnly", "-WorkloadDirectory", directory])
                result = subprocess.run(["powershell", "-NoProfile", "-File", str(script), *arguments],
                                        cwd=ROOT, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
                if case == "unbound_run":
                    self.assertIn("not executable yet", result.stderr)

    def compare(self, baseline, candidate):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("control.json", "candidate.json")]
            for path, report in zip(paths, (baseline, candidate)):
                path.write_text(json.dumps(report), encoding="utf-8")
            result = subprocess.run(
                ["powershell", "-NoProfile", "-File",
                 str(ROOT / "tools/perf/Compare-DogmosPerformance.ps1"),
                 "-BaselinePath", str(paths[0]), "-CurrentPath", str(paths[1])],
                cwd=ROOT, capture_output=True, text=True, check=False, timeout=30,
            )
        self.assertTrue(result.stdout.strip(), result.stderr)
        return result.returncode, json.loads(result.stdout)

    def test_runtime_comparison_rejects_incomparable_or_incomplete_progress(self):
        for case, expected in (
            ("seed", "identity_mismatch"),
            ("missing_rpc", "insufficient_evidence"),
            ("progress", "progress_regression"),
            ("events", "equivalence_failure"),
        ):
            with self.subTest(case=case):
                baseline, candidate = runtime_report("control"), runtime_report("candidate")
                if case == "seed":
                    candidate["identity"]["seed"] += 1
                elif case == "missing_rpc":
                    candidate["runs"][0]["metrics"]["rpc_wait_ms"] = None
                elif case == "progress":
                    candidate["runs"][0]["metrics"]["completed_cycles"] = 50
                else:
                    candidate["runs"][0]["equivalence"]["events"].reverse()
                code, result = self.compare(baseline, candidate)
                self.assertEqual(result.get("status"), expected)
                self.assertNotEqual(code, 0)
                self.assertFalse(result.get("acceptance_passed", False))

    def test_complete_runtime_evidence_retains_samples_and_separate_builds(self):
        baseline, candidate = runtime_report("control"), runtime_report("candidate")
        candidate["build"]["native_revision"] = "9" * 40
        candidate["build"]["service_sha256"] = "8" * 64
        candidate["build"]["game_dmb_sha256"] = "7" * 64
        code, result = self.compare(baseline, candidate)
        self.assertEqual(code, 0)
        self.assertEqual(result.get("status"), "evidence_complete")
        self.assertFalse(result["acceptance_passed"])
        self.assertFalse(result["performance_evaluated"])
        self.assertEqual(result["raw_runs"]["candidate"], candidate["runs"])
        self.assertEqual(result["builds"]["candidate"], candidate["build"])
        self.assertEqual(result["distributions"]["control"][0]["game_tick_ms"]["p95"], 12)

    def test_missing_or_invalid_runtime_evidence_is_not_zero(self):
        for case in ("one_run", "duplicate_run", "unpaired", "contaminated", "empty_samples",
                     "negative", "bool_sample", "unknown_mode", "missing_state", "no_resources",
                     "backward_clock", "missing_identity", "invalid_hash", "missing_game_binary", "missing_cycles",
                     "nonfinite_event", "nonfinite_metric", "same_run_across_cohorts"):
            with self.subTest(case=case):
                baseline, candidate = runtime_report("control"), runtime_report("candidate")
                run = candidate["runs"][0]
                if case == "one_run": candidate["runs"] = candidate["runs"][:1]
                elif case == "duplicate_run": candidate["runs"][1] = copy.deepcopy(run)
                elif case == "unpaired": run["pair_id"] = "missing-control"
                elif case == "contaminated": run["contaminated"] = True
                elif case == "empty_samples": run["metrics"]["game_tick_ms"] = []
                elif case == "negative": run["metrics"]["rpc_wait_ms"] = [-1, 2]
                elif case == "bool_sample": run["metrics"]["rpc_wait_ms"] = [False, 2]
                elif case == "unknown_mode": candidate["mode"] = "unknown"
                elif case == "missing_state": del run["equivalence"]["state_sha256"]
                elif case == "no_resources": del run["processes"]["dreamdaemon"]
                elif case == "backward_clock": run["processes"]["dogmosd"].reverse()
                elif case == "missing_identity": del candidate["identity"]["map_sha256"]
                elif case == "invalid_hash": candidate["build"]["shim_sha256"] = "unknown"
                elif case == "missing_game_binary": del candidate["build"]["game_dmb_sha256"]
                elif case == "missing_cycles": run["metrics"]["completed_cycles"] = None
                elif case == "nonfinite_event": run["equivalence"]["events"] = [float("nan")]
                elif case == "nonfinite_metric": run["metrics"]["rpc_wait_ms"] = [float("inf"), 1]
                elif case == "same_run_across_cohorts": run["run_id"] = baseline["runs"][0]["run_id"]
                code, result = self.compare(baseline, candidate)
                self.assertNotEqual(code, 0)
                self.assertEqual(result.get("status"), "insufficient_evidence")

    def test_job_metrics_cannot_be_declared_inapplicable(self):
        baseline, candidate = runtime_report("control"), runtime_report("candidate")
        candidate["mode"] = "jobs"
        code, result = self.compare(baseline, candidate)
        self.assertNotEqual(code, 0)
        self.assertEqual(result.get("status"), "insufficient_evidence")

    def test_growing_backlog_and_changed_state_are_rejected(self):
        for case, expected in (("cycle_age_ms", "progress_regression"),
                               ("callback_age_ms", "progress_regression"),
                               ("callbacks_pending", "progress_regression"),
                               ("state", "equivalence_failure")):
            with self.subTest(case=case):
                baseline, candidate = runtime_report("control"), runtime_report("candidate")
                run = candidate["runs"][0]
                if case == "state": run["equivalence"]["state_sha256"] = "5" * 64
                else: run["metrics"][case] = [0, 1000, 100000]
                code, result = self.compare(baseline, candidate)
                self.assertNotEqual(code, 0)
                self.assertEqual(result.get("status"), expected)


if __name__ == "__main__":
    unittest.main()
