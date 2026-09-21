"""Summarize a RIFT first-three-minute run without merging process footprints."""

import argparse
import csv
import datetime as dt
import json
import math
import re
import statistics
from pathlib import Path


def records(path):
    with path.open(encoding="utf-8-sig") as stream:
        for line in stream:
            if line.strip():
                yield json.loads(line)


def summary(values):
    values = sorted(value for value in values if value is not None)
    if not values:
        return None
    return dict(count=len(values), minimum=values[0], median=statistics.median(values),
                p95=values[math.ceil(0.95 * len(values)) - 1], maximum=values[-1])


def dense_process_resources(run, begin, end):
    """Keep each process lifetime separate when computing CPU and sampling coverage."""
    path = run / "processes-250ms.csv"
    if not path.exists():
        return None
    instances = {}
    with path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            if row["role"] not in ("dreamdaemon", "dogmosd"):
                continue
            timestamp = dt.datetime.fromisoformat(row["utc"].replace("Z", "+00:00")).timestamp()
            phase = "gameplay" if begin <= timestamp <= end else "initialization" if timestamp < begin else None
            if phase is None:
                continue
            key = (row["role"], row["pid"], row["start_utc"], phase)
            instances.setdefault(key, []).append((timestamp, row))
    result = []
    for (role, pid, start, phase), rows in instances.items():
        rows.sort(key=lambda item: item[0])
        first_time, first = rows[0]
        last_time, last = rows[-1]
        result.append(dict(role=role, pid=int(pid), start_utc=start, phase=phase,
            sample_count=len(rows), first_sample_utc=first["utc"], last_sample_utc=last["utc"],
            observed_seconds=last_time - first_time,
            sampled_cpu_seconds=float(last["cpu_seconds"]) - float(first["cpu_seconds"]),
            sample_gap_ms=summary((right[0] - left[0]) * 1000 for left, right in zip(rows, rows[1:])),
            peaks_bytes={key: max(int(row[key]) for _, row in rows)
                         for key in ("private_bytes", "working_set_bytes", "virtual_bytes")}))
    metadata_path = run / "processes-250ms.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8-sig")) if metadata_path.exists() else None
    return dict(metadata=metadata, instances=result)


def analyze(run):
    logs = run / "artifacts/data/logs/rift"
    samples = list(records(logs / "dogmos-performance.jsonl"))
    gameplay = [s for s in samples if s["shift_seconds"] is not None]
    if not gameplay:
        raise ValueError("No gameplay samples were recorded")
    begin = float(gameplay[0]["utc"]) - gameplay[0]["shift_seconds"]
    end = begin + 180
    window = [s for s in gameplay if s["shift_seconds"] <= 180]
    last_minute = [s for s in window if s["shift_seconds"] >= 120]
    resources = {}
    for event in records(run / "events.ndjson"):
        if "timestamp" not in event:
            continue
        timestamp = dt.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp()
        for process in event.get("data", {}).get("resource_samples", []):
            role = process.get("role", "").lower()
            if role not in ("dreamdaemon", "dogmosd"):
                continue
            phase = "gameplay" if begin <= timestamp <= end else "initialization" if timestamp < begin else None
            if phase is None:
                continue
            bucket = resources.setdefault(role, {}).setdefault(phase, {})
            for key in ("privateBytes", "workingSetBytes"):
                if key in process:
                    bucket[key] = max(bucket.get(key, 0), process[key])
    initialization = {}
    for record in records(logs / "runtime.log.json"):
        message = record.get("msg", "")
        match = re.search(r"Initialized (.+) subsystem within ([\d.]+) seconds", message)
        if match:
            initialization[match[1]] = float(match[2])
        match = re.search(r"Initializations complete within ([\d.]+) seconds", message)
        if match:
            initialization["total"] = float(match[1])
    report = json.loads((run / "summary.json").read_text(encoding="utf-8-sig"))
    diagnostic_profiling = any(s.get("diagnostic_procedure_profiling",
                                    s.get("procedure_profiling", False)) for s in samples)
    profile_dumps = sorted(path.relative_to(logs).as_posix()
                           for path in logs.glob("profiler/profiler-*.json"))
    return {
        "run_id": run.name,
        "rift_status": report["status"],
        "repository": report.get("repository"),
        "tool_versions": report.get("tool_versions"),
        "maps": sorted({s["map"] for s in gameplay}),
        "seeds": sorted({s["seed"] for s in gameplay}),
        # A drift-triggered DumpFile uses PROFILE_REFRESH, which starts profiling.
        # Missing dumps do not prove that profiling remained off throughout the run.
        "procedure_profiling": True if diagnostic_profiling or profile_dumps else None,
        "diagnostic_procedure_profiling": diagnostic_profiling,
        "procedure_profile_dumps": profile_dumps,
        "complete": any(s["complete"] for s in gameplay),
        "observed_shift_seconds": gameplay[-1]["shift_seconds"],
        "initialization_seconds": initialization,
        "gameplay": {key: summary(s[key] for s in window) for key in
                     ("active_turfs", "turf_cost_ms", "groups_cost_ms", "equalize_cost_ms")},
        "last_minute_active_turfs": summary(s["active_turfs"] for s in last_minute),
        "air_cycles_observed": window[-1]["air_cycles"] - window[0]["air_cycles"],
        "first_air_cycle_progress_seconds": next((s["shift_seconds"] for s in window
            if s["air_cycles"] > window[0]["air_cycles"]), None),
        "gameplay_queues": {key: summary(s.get(key) for s in window) for key in
            ("adjacency_queue", "pipe_rebuild_queue", "pipe_expansion_queue", "currentrun_remaining")},
        "process_peaks_bytes": resources,
        "dense_process_resources": dense_process_resources(run, begin, end),
        "active_location_samples": [dict(shift_seconds=s["shift_seconds"], locations=s["active_locations"])
                                    for s in gameplay if "active_locations" in s],
        "limits": ["Test build, fixed seed and empty player population; match controls to this workload.",
                   "Profiling evidence means active at some point, not continuous coverage; null means unknown, not unprofiled.",
                   "The test framework creates its fixture room about ten seconds after round start.",
                   "Stage costs are rolling averages; they are not individual frame durations.",
                   "Gameplay origin is first observed playing state, within the sampler's scheduling delay."],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    result = analyze(arguments.run)
    arguments.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "active_location_samples"}, indent=2))
