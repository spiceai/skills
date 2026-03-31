#!/usr/bin/env python3
"""Build benchmark.json for a skill's iteration directory."""
import json
import os
import sys
import math
from datetime import datetime

def load_json(path):
    with open(path) as f:
        return json.load(f)

def stats(values):
    n = len(values)
    if n == 0:
        return {"mean": 0, "stddev": 0, "min": 0, "max": 0}
    mean = sum(values) / n
    if n > 1:
        variance = sum((x - mean) ** 2 for x in values) / (n - 1)
        stddev = math.sqrt(variance)
    else:
        stddev = 0
    return {"mean": round(mean, 3), "stddev": round(stddev, 3), "min": round(min(values), 3), "max": round(max(values), 3)}

def build_benchmark(iteration_dir, skill_name):
    eval_dirs = sorted([
        d for d in os.listdir(iteration_dir)
        if os.path.isdir(os.path.join(iteration_dir, d))
    ])

    runs = []
    with_skill_rates = []
    without_skill_rates = []
    with_skill_times = []
    without_skill_times = []
    with_skill_tokens = []
    without_skill_tokens = []

    for eval_dir_name in eval_dirs:
        eval_dir = os.path.join(iteration_dir, eval_dir_name)
        metadata_path = os.path.join(eval_dir, "eval_metadata.json")
        grading_path = os.path.join(eval_dir, "grading.json")

        if not os.path.exists(metadata_path) or not os.path.exists(grading_path):
            continue

        metadata = load_json(metadata_path)
        grading = load_json(grading_path)

        for config in ["with_skill", "without_skill"]:
            if config not in grading:
                continue

            g = grading[config]
            expectations = g.get("expectations", [])
            passed = sum(1 for e in expectations if e["passed"])
            total = len(expectations)
            pass_rate = passed / total if total > 0 else 0

            timing_path = os.path.join(eval_dir, config, "timing.json")
            time_secs = 0
            tokens = 0
            if os.path.exists(timing_path):
                timing = load_json(timing_path)
                time_secs = timing.get("total_duration_seconds", timing.get("duration_ms", 0) / 1000)
                tokens = timing.get("total_tokens", 0)

            run = {
                "eval_id": metadata.get("eval_id", 0),
                "eval_name": metadata.get("eval_name", eval_dir_name),
                "configuration": config,
                "run_number": 1,
                "result": {
                    "pass_rate": round(pass_rate, 3),
                    "passed": passed,
                    "failed": total - passed,
                    "total": total,
                    "time_seconds": round(time_secs, 1),
                    "tokens": tokens,
                    "errors": 0
                },
                "expectations": expectations
            }
            runs.append(run)

            if config == "with_skill":
                with_skill_rates.append(pass_rate)
                with_skill_times.append(time_secs)
                with_skill_tokens.append(tokens)
            else:
                without_skill_rates.append(pass_rate)
                without_skill_times.append(time_secs)
                without_skill_tokens.append(tokens)

    ws_rate = stats(with_skill_rates)
    wos_rate = stats(without_skill_rates)
    ws_time = stats(with_skill_times)
    wos_time = stats(without_skill_times)
    ws_tokens = stats(with_skill_tokens)
    wos_tokens = stats(without_skill_tokens)

    delta_rate = ws_rate["mean"] - wos_rate["mean"]
    delta_time = ws_time["mean"] - wos_time["mean"]
    delta_tokens = ws_tokens["mean"] - wos_tokens["mean"]

    benchmark = {
        "metadata": {
            "skill_name": skill_name,
            "timestamp": datetime.now().isoformat(),
            "evals_run": list(set(r["eval_id"] for r in runs)),
            "runs_per_configuration": 1
        },
        "runs": runs,
        "run_summary": {
            "with_skill": {
                "pass_rate": ws_rate,
                "time_seconds": ws_time,
                "tokens": ws_tokens
            },
            "without_skill": {
                "pass_rate": wos_rate,
                "time_seconds": wos_time,
                "tokens": wos_tokens
            },
            "delta": {
                "pass_rate": f"{delta_rate:+.3f}",
                "time_seconds": f"{delta_time:+.1f}",
                "tokens": f"{delta_tokens:+.0f}"
            }
        },
        "notes": []
    }

    # Add analyst notes
    if delta_rate > 0:
        benchmark["notes"].append(f"Skill improves pass rate by {delta_rate:.1%} ({ws_rate['mean']:.1%} vs {wos_rate['mean']:.1%})")
    elif delta_rate == 0:
        benchmark["notes"].append(f"Pass rates are equal ({ws_rate['mean']:.1%}) — skill doesn't improve quantitative metrics on these evals")

    # Check for non-discriminating assertions
    for run in runs:
        if run["configuration"] == "without_skill" and run["result"]["pass_rate"] == 1.0:
            benchmark["notes"].append(f"Eval '{run['eval_name']}' passes all assertions without skill — consider harder assertions")

    out_path = os.path.join(iteration_dir, "benchmark.json")
    with open(out_path, "w") as f:
        json.dump(benchmark, f, indent=2)

    print(f"Benchmark written to {out_path}")
    print(f"  with_skill pass rate: {ws_rate['mean']:.1%} ± {ws_rate['stddev']:.1%}")
    print(f"  without_skill pass rate: {wos_rate['mean']:.1%} ± {wos_rate['stddev']:.1%}")
    print(f"  delta: {delta_rate:+.1%}")

if __name__ == "__main__":
    iteration_dir = sys.argv[1]
    skill_name = sys.argv[2]
    build_benchmark(iteration_dir, skill_name)
