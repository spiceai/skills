#!/usr/bin/env python3
"""Run evals for one or all skills using `claude -p`.

Usage:
  python scripts/run_evals.py                    # run all skills
  python scripts/run_evals.py spice-setup        # run one skill
  python scripts/run_evals.py --grade            # run + grade
  python scripts/run_evals.py --skill spice-ai   # alternate syntax
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS_DIR = ROOT / "skills"


def discover_skills():
    """Return sorted list of skill directory names that have evals."""
    skills = []
    for d in sorted(SKILLS_DIR.iterdir()):
        if d.is_dir() and (d / "evals" / "evals.json").exists():
            skills.append(d.name)
    return skills


def load_evals(skill_name):
    path = SKILLS_DIR / skill_name / "evals" / "evals.json"
    with open(path) as f:
        return json.load(f)


def run_single_eval(skill_name, eval_entry, workspace, with_skill=True):
    """Run a single eval prompt via `claude -p` and save output."""
    eval_id = eval_entry["id"]
    variant = "with_skill" if with_skill else "without_skill"
    out_dir = workspace / f"eval-{eval_id}" / variant / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)

    prompt = eval_entry["prompt"]

    cmd = ["claude", "-p", prompt, "--output-format", "text"]
    if with_skill:
        cmd.extend(["--plugin-dir", str(ROOT)])
    else:
        # Disable skills so baseline doesn't pick up the plugin via auto-discovery
        cmd.append("--disable-slash-commands")

    # Run baseline from /tmp so it doesn't auto-discover CLAUDE.md or plugins
    run_cwd = "/tmp" if not with_skill else None

    start = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=run_cwd,
        )
        duration_ms = int((time.time() - start) * 1000)
        response = result.stdout
        if result.returncode != 0 and not response:
            response = f"ERROR (exit {result.returncode}): {result.stderr}"
    except subprocess.TimeoutExpired:
        duration_ms = 120000
        response = "ERROR: timed out after 120s"
    except FileNotFoundError:
        print("  ERROR: `claude` CLI not found. Install it first.", file=sys.stderr)
        sys.exit(1)

    # Save response
    (out_dir / "response.md").write_text(response)

    # Save timing
    timing = {
        "duration_ms": duration_ms,
        "total_duration_seconds": round(duration_ms / 1000, 1),
    }
    (out_dir.parent / "timing.json").write_text(json.dumps(timing, indent=2))

    # Save eval_metadata.json
    metadata = {
        "eval_id": eval_id,
        "eval_name": f"eval-{eval_id}",
        "prompt": prompt,
        "assertions": eval_entry.get("assertions", []),
    }
    meta_path = workspace / f"eval-{eval_id}" / "eval_metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2))

    return response


def run_skill_evals(skill_name, workspace, run_baseline=True):
    """Run all evals for a single skill."""
    data = load_evals(skill_name)
    evals = data.get("evals", [])
    print(f"\n{'='*60}")
    print(f"  {skill_name}: {len(evals)} evals")
    print(f"{'='*60}")

    for entry in evals:
        eid = entry["id"]
        print(f"  [{eid}] with_skill ... ", end="", flush=True)
        run_single_eval(skill_name, entry, workspace, with_skill=True)
        print("done")

        if run_baseline:
            print(f"  [{eid}] without_skill ... ", end="", flush=True)
            run_single_eval(skill_name, entry, workspace, with_skill=False)
            print("done")


def grade_skill(skill_name, workspace):
    """Grade eval results using grade_eval.py."""
    grade_script = ROOT / "grade_eval.py"
    if not grade_script.exists():
        print(f"  WARNING: grade_eval.py not found, skipping grading", file=sys.stderr)
        return

    eval_dirs = sorted(d for d in workspace.iterdir() if d.is_dir() and d.name.startswith("eval-"))
    for eval_dir in eval_dirs:
        try:
            subprocess.run(
                [sys.executable, str(grade_script), str(eval_dir)],
                capture_output=True,
                text=True,
            )
        except Exception as e:
            print(f"  WARNING: grading failed for {eval_dir.name}: {e}", file=sys.stderr)


def build_benchmark(skill_name, workspace):
    """Build benchmark.json using build_benchmark.py."""
    bench_script = ROOT / "build_benchmark.py"
    if not bench_script.exists():
        print(f"  WARNING: build_benchmark.py not found, skipping benchmark", file=sys.stderr)
        return

    subprocess.run(
        [sys.executable, str(bench_script), str(workspace), skill_name],
        capture_output=True,
        text=True,
    )


def main():
    parser = argparse.ArgumentParser(description="Run skill evals")
    parser.add_argument("skill", nargs="?", help="Skill name (omit for all)")
    parser.add_argument("--skill", dest="skill_flag", help="Skill name (alternate)")
    parser.add_argument("--grade", action="store_true", help="Grade results after running")
    parser.add_argument("--no-baseline", action="store_true", help="Skip baseline (without_skill) runs")
    parser.add_argument("--output-dir", help="Output directory (default: <skill>-workspace/)")
    parser.add_argument("--iteration", type=int, default=1, help="Iteration number (default: 1)")
    args = parser.parse_args()

    skill_name = args.skill or args.skill_flag
    skills = [skill_name] if skill_name else discover_skills()

    if not skills:
        print("No skills with evals found.", file=sys.stderr)
        sys.exit(1)

    print(f"Running evals for {len(skills)} skill(s): {', '.join(skills)}")

    for skill in skills:
        if args.output_dir:
            workspace = Path(args.output_dir) / f"iteration-{args.iteration}"
        else:
            workspace = ROOT / f"{skill}-workspace" / f"iteration-{args.iteration}"
        workspace.mkdir(parents=True, exist_ok=True)

        run_skill_evals(skill, workspace, run_baseline=not args.no_baseline)

        if args.grade:
            print(f"  Grading {skill}...")
            grade_skill(skill, workspace)
            build_benchmark(skill, workspace)
            bench_path = workspace / "benchmark.json"
            if bench_path.exists():
                bench = json.load(open(bench_path))
                summary = bench.get("run_summary", {})
                ws = summary.get("with_skill", {}).get("pass_rate", {})
                wos = summary.get("without_skill", {}).get("pass_rate", {})
                print(f"  Benchmark: with_skill={ws.get('mean', '?')}, without_skill={wos.get('mean', '?')}")

    print(f"\nDone. Results in *-workspace/ directories.")


if __name__ == "__main__":
    main()
