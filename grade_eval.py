#!/usr/bin/env python3
"""Grade eval outputs against assertions from eval_metadata.json"""
import json
import re
import sys
import os

def grade(eval_dir):
    metadata_path = os.path.join(eval_dir, "eval_metadata.json")
    with open(metadata_path) as f:
        metadata = json.load(f)

    results = {}
    for variant in ["with_skill", "without_skill"]:
        response_path = os.path.join(eval_dir, variant, "outputs", "response.md")
        if not os.path.exists(response_path):
            results[variant] = {"status": "missing", "expectations": []}
            continue
        with open(response_path) as f:
            content = f.read()

        expectations = []
        for assertion in metadata.get("assertions", []):
            name = assertion["name"]
            atype = assertion["type"]
            value = assertion["value"]

            if atype == "contains":
                passed = value in content
            elif atype == "regex":
                passed = bool(re.search(value, content))
            else:
                passed = False

            evidence = ""
            if passed:
                if atype == "contains":
                    idx = content.find(value)
                    start = max(0, idx - 30)
                    end = min(len(content), idx + len(value) + 30)
                    evidence = content[start:end].replace("\n", " ")
                elif atype == "regex":
                    m = re.search(value, content)
                    if m:
                        idx = m.start()
                        start = max(0, idx - 30)
                        end = min(len(content), m.end() + 30)
                        evidence = content[start:end].replace("\n", " ")
            else:
                evidence = f"'{value}' not found in response"

            expectations.append({
                "text": name,
                "passed": passed,
                "evidence": evidence
            })

        pass_count = sum(1 for e in expectations if e["passed"])
        total = len(expectations)
        results[variant] = {
            "status": "graded",
            "pass_rate": f"{pass_count}/{total}",
            "expectations": expectations
        }

    grading_path = os.path.join(eval_dir, "grading.json")
    with open(grading_path, "w") as f:
        json.dump(results, f, indent=2)

    return results

if __name__ == "__main__":
    eval_dir = sys.argv[1]
    results = grade(eval_dir)
    for variant, data in results.items():
        if data["status"] == "graded":
            print(f"  {variant}: {data['pass_rate']} assertions passed")
            for exp in data["expectations"]:
                status = "PASS" if exp["passed"] else "FAIL"
                print(f"    [{status}] {exp['text']}")
