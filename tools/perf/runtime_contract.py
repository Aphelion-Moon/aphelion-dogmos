"""Validate paired runtime observations; complete evidence is not a speedup claim."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import tomllib


SERIES = (
    "game_tick_ms", "ssair_main_thread_ms", "rpc_wait_ms", "native_prepare_ms",
    "native_commit_ms", "cycle_age_ms", "job_age_ms", "callback_age_ms", "callbacks_pending",
)
JOB_ONLY = {"native_prepare_ms", "native_commit_ms", "job_age_ms", "conflicts"}
IDENTITY = {
    "map", "map_sha256", "seed", "features", "byond_version", "duration_seconds",
    "scenario_sha256", "command_sequence_sha256", "settings",
}
BUILD = {"game_revision": 40, "game_dmb_sha256": 64, "native_revision": 40, "shim_sha256": 64,
         "service_sha256": 64, "bindings_sha256": 64, "contract_sha256": 64}


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def digest(value, size=64):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % size, value) is not None


def series(value, label):
    require(isinstance(value, list) and len(value) >= 2, f"{label}: need raw observations")
    require(all(number(item) for item in value), f"{label}: non-finite, negative or nonnumeric observation")


def validate_report(report, cohort, minimum_repetitions):
    require(isinstance(report, dict), f"{cohort}: report must be an object")
    try:
        json.dumps(report, allow_nan=False)
    except ValueError as error:
        raise EvidenceError(f"{cohort}: non-finite observation or identity") from error
    require(report.get("schema_version") == 2 and report.get("kind") == "runtime_isolation",
            f"{cohort}: expected runtime_isolation schema 2")
    require(report.get("cohort") == cohort, f"{cohort}: wrong cohort label")
    require(report.get("mode") in ("synchronous", "jobs"), f"{cohort}: unknown mode")
    identity = report.get("identity")
    require(isinstance(identity, dict) and IDENTITY <= identity.keys(), f"{cohort}: incomplete identity")
    for key in ("map_sha256", "scenario_sha256", "command_sequence_sha256"):
        require(digest(identity[key]), f"{cohort}.identity.{key}: expected SHA-256")
    require(isinstance(identity["map"], str) and identity["map"].strip(), f"{cohort}: missing map")
    require(isinstance(identity["byond_version"], str) and identity["byond_version"].strip(),
            f"{cohort}: missing BYOND version")
    require(type(identity["seed"]) is int, f"{cohort}: seed must be an integer")
    require(number(identity["duration_seconds"]) and identity["duration_seconds"] > 0,
            f"{cohort}: invalid duration")
    features = identity["features"]
    require(isinstance(features, list) and all(isinstance(x, str) and x for x in features),
            f"{cohort}: invalid features")
    require(features == sorted(set(features)), f"{cohort}: features must be sorted and unique")
    require(isinstance(identity["settings"], dict) and identity["settings"], f"{cohort}: missing settings")
    build = report.get("build")
    require(isinstance(build, dict), f"{cohort}: missing build identity")
    for key, size in BUILD.items():
        require(digest(build.get(key), size), f"{cohort}.build.{key}: missing or invalid digest")
    runs = report.get("runs")
    require(isinstance(runs, list) and len(runs) >= minimum_repetitions,
            f"{cohort}: need at least {minimum_repetitions} runs")
    seen_runs, seen_pairs = set(), set()
    for run in runs:
        require(isinstance(run, dict), f"{cohort}: invalid run")
        for name, seen in (("run_id", seen_runs), ("pair_id", seen_pairs)):
            value = run.get(name)
            require(isinstance(value, str) and value and value not in seen,
                    f"{cohort}: missing or duplicate {name}")
            seen.add(value)
        label = f"{cohort}.{run['run_id']}"
        require(run.get("contaminated") is False, f"{label}: contaminated or unclassified run")
        metrics, inactive = run.get("metrics"), run.get("not_applicable", {})
        require(isinstance(metrics, dict) and isinstance(inactive, dict), f"{label}: missing metrics")
        require(set(inactive) <= JOB_ONLY, f"{label}: required metric declared inapplicable")
        for name in (*SERIES, "completed_cycles", "conflicts"):
            value = metrics.get(name)
            metric_label = f"{label}.{name}"
            if name in inactive:
                require(report["mode"] == "synchronous" and value is None
                        and isinstance(inactive[name], str) and inactive[name].strip(),
                        f"{metric_label}: invalid applicability declaration")
            elif name in ("completed_cycles", "conflicts"):
                require(type(value) is int and value >= 0, f"{metric_label}: need a nonnegative counter")
            else:
                series(value, metric_label)
                if name == "callbacks_pending":
                    require(all(type(x) is int for x in value), f"{metric_label}: need integer counts")
        equivalent = run.get("equivalence")
        require(isinstance(equivalent, dict) and digest(equivalent.get("state_sha256")),
                f"{label}: missing numerical-state evidence")
        require(isinstance(equivalent.get("events"), list), f"{label}: missing ordered events")
        processes = run.get("processes")
        require(isinstance(processes, dict), f"{label}: missing process samples")
        for role in ("dreamdaemon", "dogmosd"):
            samples = processes.get(role)
            require(isinstance(samples, list) and len(samples) >= 2, f"{label}.{role}: missing samples")
            prior_time, prior_cpu = -1, -1
            for sample in samples:
                require(isinstance(sample, dict), f"{label}.{role}: invalid sample")
                for field in ("elapsed_ms", "private_bytes", "working_set_bytes", "virtual_bytes", "cpu_total_seconds"):
                    require(number(sample.get(field)), f"{label}.{role}.{field}: invalid sample")
                require(sample["elapsed_ms"] > prior_time and sample["cpu_total_seconds"] >= prior_cpu,
                        f"{label}.{role}: clock or CPU counter moved backward")
                prior_time, prior_cpu = sample["elapsed_ms"], sample["cpu_total_seconds"]
            duration_ms = identity["duration_seconds"] * 1000
            require(samples[0]["elapsed_ms"] <= duration_ms * 0.01
                    and samples[-1]["elapsed_ms"] >= duration_ms * 0.99,
                    f"{label}.{role}: incomplete observation window")
    return seen_pairs


def distribution(values):
    ordered = sorted(values)
    # Nearest rank, computed per run. Never pool percentiles from dissimilar runs.
    return {"count": len(values), "p50": ordered[math.ceil(len(values) * 0.5) - 1],
            "p95": ordered[math.ceil(len(values) * 0.95) - 1],
            "p99": ordered[math.ceil(len(values) * 0.99) - 1], "max": ordered[-1]}


def compare_reports(baseline, candidate, minimum_repetitions=3):
    result = {"schema_version": 2, "kind": "runtime_isolation", "acceptance_passed": False,
              "performance_evaluated": False, "server_memory_is_separate": True,
              "server_memory_is_in_dreamdaemon_total": False, "mismatches": []}

    def finish(status, reasons):
        return {**result, "status": status, "reasons": reasons,
                "comparable": status in ("evidence_complete", "progress_regression", "equivalence_failure")}

    try:
        require(type(minimum_repetitions) is int and minimum_repetitions >= 3, "invalid repetition budget")
        control_pairs = validate_report(baseline, "control", minimum_repetitions)
        candidate_pairs = validate_report(candidate, "candidate", minimum_repetitions)
        require(control_pairs == candidate_pairs, "unpaired control/candidate runs")
        require(not ({r["run_id"] for r in baseline["runs"]} & {r["run_id"] for r in candidate["runs"]}),
                "run identity reused across cohorts")
    except EvidenceError as error:
        return finish("insufficient_evidence", [str(error)])
    result["mismatches"] = sorted(key for key in baseline["identity"].keys() | candidate["identity"].keys()
                                  if baseline["identity"].get(key) != candidate["identity"].get(key))
    if result["mismatches"]:
        return finish("identity_mismatch", result["mismatches"])
    result["raw_runs"] = {"control": baseline["runs"], "candidate": candidate["runs"]}
    result["builds"] = {"control": baseline["build"], "candidate": candidate["build"]}
    result["modes"] = {"control": baseline["mode"], "candidate": candidate["mode"]}
    result["distributions"] = {
        cohort: [{"run_id": run["run_id"], **{
            name: distribution(run["metrics"][name]) if run["metrics"].get(name) is not None else None
            for name in SERIES}} for run in report["runs"]]
        for cohort, report in (("control", baseline), ("candidate", candidate))
    }
    controls = {run["pair_id"]: run for run in baseline["runs"]}
    for after in candidate["runs"]:
        before = controls[after["pair_id"]]
        if before["equivalence"] != after["equivalence"]:
            return finish("equivalence_failure", [f"pair {after['pair_id']}: numerical state or ordered events differ"])
    regressions = []
    for after in candidate["runs"]:
        before = controls[after["pair_id"]]
        left, right = before["metrics"], after["metrics"]
        if right["completed_cycles"] < left["completed_cycles"]:
            regressions.append(f"pair {after['pair_id']}: fewer completed cycles")
        for name in ("cycle_age_ms", "callback_age_ms", "callbacks_pending", "job_age_ms"):
            current, control = right.get(name), left.get(name)
            if current is not None and current[-1] > current[0] and (control is None or current[-1] > control[-1]):
                regressions.append(f"pair {after['pair_id']}: growing {name}")
    if regressions:
        return finish("progress_regression", regressions)
    return finish("evidence_complete", ["Evidence prerequisites passed; runtime performance/noise acceptance remains separate."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("budget", type=Path)
    args = parser.parse_args()
    try:
        raw = [path.read_bytes() for path in (args.baseline, args.candidate)]
        reports = [json.loads(data.decode("utf-8-sig")) for data in raw]
        budget = tomllib.loads(args.budget.read_text(encoding="utf-8-sig"))
        result = compare_reports(*reports, minimum_repetitions=budget["minimum_repetitions"])
        result["report_sha256"] = dict(zip(("control", "candidate"), (hashlib.sha256(data).hexdigest() for data in raw)))
    except (OSError, ValueError, KeyError) as error:
        result = {"status": "insufficient_evidence", "acceptance_passed": False,
                  "performance_evaluated": False, "reasons": [str(error)]}
    print(json.dumps(result, allow_nan=False, separators=(",", ":")))
    return {"evidence_complete": 0, "identity_mismatch": 2, "progress_regression": 3,
            "equivalence_failure": 3}.get(result["status"], 4)


if __name__ == "__main__":
    sys.exit(main())
