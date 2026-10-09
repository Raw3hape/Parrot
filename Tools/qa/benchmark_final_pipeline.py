#!/usr/bin/env python3
"""Serialize real-model timings and compare identical synthetic audio outputs."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time
from compare_native_models import tokens, edit_distance


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    references = tokens(" ".join(case["text"] for case in json.loads(args.manifest.read_text())["cases"]))
    rows = []
    for index, (engine, workers) in enumerate([("whisper", 1), ("whisper", 4), ("whisper", 4), ("whisper", 1), ("hybrid", 4)]):
        logpath = args.output / f"{index}-{engine}-{workers}.log"
        command = [str(args.app.resolve()), "--final-transcription-test", str(args.audio), engine,
                   str(args.model_root), str(workers), "--print-fixture-transcript"]
        started = time.monotonic()
        with logpath.open("w") as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            resource = {"name": "serialized final pipeline benchmark", "pid": child.pid,
                        "engine": engine, "workers": workers, "project": str(Path.cwd()),
                        "status": "running", "stop_condition": "completion or180s"}
            (args.output / "resource.json").write_text(json.dumps(resource, indent=2) + "\n")
            try:
                code = child.wait(timeout=180)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=10)
                code = 124
            resource.update(status="exited", exit_code=code, wall_seconds=time.monotonic()-started)
            (args.output / "resource.json").write_text(json.dumps(resource, indent=2) + "\n")
        if code: raise RuntimeError(f"Benchmark failed: {engine}/{workers} exit={code}")
        response = next(json.loads(line) for line in logpath.read_text().splitlines()
                        if line.startswith("{") and json.loads(line).get("diagnostic") == "final_transcript")
        if not response["timestamps_valid"] or not response["worker_exited"]:
            raise RuntimeError("Benchmark integrity failed")
        normalized = tokens(response.pop("fixture_text"))
        errors = edit_distance(references, normalized)
        row = {"engine": engine, "workers": workers, "word_errors": errors,
               "reference_words": len(references), "log": logpath.name,
               "normalized_words_sha256": hashlib.sha256(" ".join(normalized).encode()).hexdigest(), **response}
        rows.append(row)
        print(json.dumps({k: row[k] for k in ["engine", "workers", "word_errors", "elapsed_seconds"]}), flush=True)
        (args.output / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
    serial = [r for r in rows if r["engine"] == "whisper" and r["workers"] == 1]
    batched = [r for r in rows if r["engine"] == "whisper" and r["workers"] == 4]
    one = statistics.median(r["elapsed_seconds"] for r in serial)
    four = statistics.median(r["elapsed_seconds"] for r in batched)
    summary = {"serial_median_seconds": one, "batch4_median_seconds": four,
               "speedup": one/four, "whisper_outputs_identical": len({r["content_sha256"] for r in serial+batched}) == 1,
               "whisper_normalized_words_identical": len({r["normalized_words_sha256"] for r in serial+batched}) == 1,
               "serial_errors": [r["word_errors"] for r in serial], "batch4_errors": [r["word_errors"] for r in batched],
               "hybrid_errors": rows[-1]["word_errors"], "hybrid_seconds": rows[-1]["elapsed_seconds"],
               "includes_local_model_prepare": True}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
