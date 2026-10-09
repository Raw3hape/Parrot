#!/usr/bin/env python3
"""Use the signed app's exact legacy Whisper decoding policy for quality baseline."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from compare_native_models import tokens, edit_distance


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", default="whisper", choices=["whisper", "hybrid", "qwen", "moss"])
    parser.add_argument("--workers", default=1, type=int)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = json.loads(args.manifest.read_text())["cases"]
    results = []
    for case in cases:
        command = [str(args.app.resolve()), "--final-transcription-test", str(args.input_root / case["file"]), args.engine, str(args.model_root), str(args.workers), "--print-fixture-transcript"]
        logpath = args.output / f"{case['id']}.log"
        started = time.monotonic()
        with logpath.open("w") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            resource = {"name": "legacy Whisper quality baseline", "case": case["id"], "pid": process.pid, "project": str(Path.cwd()), "stop_condition": "completion or120s", "status": "running"}
            resource_path = args.output / "resource.json"
            resource_path.write_text(json.dumps(resource, indent=2) + "\n")
            try:
                code = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
                code = 124
            resource.update(status="exited", exit_code=code, elapsed_seconds=round(time.monotonic()-started,3))
            resource_path.write_text(json.dumps(resource, indent=2) + "\n")
        if code:
            raise RuntimeError(f"Legacy baseline fixture failed: {case['id']} exit={code}")
        parsed = [json.loads(line) for line in logpath.read_text().splitlines() if line.startswith("{")]
        response = next((row for row in parsed if row.get("diagnostic") == "final_transcript"), None)
        if not response or not response.get("fixture_text") or not response.get("timestamps_valid"):
            raise RuntimeError("Baseline returned incomplete fixture data")
        reference = tokens(case["text"])
        errors = edit_distance(reference, tokens(response["fixture_text"]))
        row = {"id": case["id"], "language": case["language"], "reference_words": len(reference), "word_errors": errors, "wer": errors/max(1,len(reference)), "duration":case["duration"], "wall_seconds": resource["elapsed_seconds"], "response": response}
        results.append(row)
        (args.output/f"{args.engine}-results.json").write_text(json.dumps({"cases":results},ensure_ascii=False,indent=2)+"\n")
        print(json.dumps({"case":case["id"],"words":len(reference),"errors":errors,"seconds":row['wall_seconds']}),flush=True)
    summary = {"engine":args.engine,"completed_cases":len(results),"declared_cases":len(cases),"words":sum(r['reference_words'] for r in results),"errors":sum(r['word_errors'] for r in results)}
    summary['wer']=summary['errors']/summary['words']
    (args.output/f'{args.engine}-summary.json').write_text(json.dumps(summary,indent=2)+"\n")


if __name__ == "__main__":
    main()
