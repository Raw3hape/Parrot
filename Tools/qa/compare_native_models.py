#!/usr/bin/env python3
"""Supervise native models on a declared corpus; keep decoded text on disk."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import unicodedata
import re


def tokens(text):
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е").replace("’", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)?", normalized, flags=re.UNICODE)


def edit_distance(reference, actual):
    previous = list(range(len(actual) + 1))
    for index, token in enumerate(reference, 1):
        current = [index]
        for column, other in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[column] + 1, previous[column - 1] + (token != other)))
        previous = current
    return previous[-1]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    corpus = json.loads((args.corpus / "manifest.json").read_text())
    overall = []
    for engine in ("qwen", "moss"):
        results = []
        received = queue.Queue()
        with (args.output / f"{engine}-stderr.log").open("w") as stderr:
            started = time.monotonic()
            environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
            process = subprocess.Popen([str(args.worker.resolve()), "--engine", engine, "--model-dir", str((args.models / engine).resolve())], cwd="/", env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True, bufsize=1)
            resource = {"name": f"{engine} native corpus", "pid": process.pid, "project": str(Path.cwd()), "stop_condition": "ten requests complete; startup120s, each inference120s, exact-child shutdown10s", "status": "running"}
            resource_path = args.output / f"{engine}-resource.json"
            resource_path.write_text(json.dumps(resource, indent=2) + "\n")
            def read():
                try:
                    for line in process.stdout:
                        received.put(line)
                finally:
                    received.put(None)
            reading = threading.Thread(target=read, daemon=True)
            reading.start()
            try:
                first = received.get(timeout=120)
                if first is None:
                    raise RuntimeError("Worker exited before its ready response")
                ready = json.loads(first)
                if ready.get("event") != "ready":
                    raise RuntimeError("Worker did not emit a valid ready response")
                print(json.dumps({"engine": engine, "ready_seconds": round(time.monotonic()-started,3)}), flush=True)
                for case in corpus["cases"]:
                    request = {"id": case["id"], "audioPath": str((args.corpus / case["file"]).resolve()), "vocabulary": "", "language": None, "maxTokens": 2048}
                    began = time.monotonic()
                    process.stdin.write(json.dumps(request) + "\n")
                    process.stdin.flush()
                    line = received.get(timeout=120)
                    if line is None:
                        raise RuntimeError("Worker exited during an audio request")
                    result = json.loads(line)
                    if result.get("id") != case["id"]:
                        raise RuntimeError("Worker response identity mismatch")
                    if result.get("error") or result.get("truncated"):
                        raise RuntimeError("Native inference did not complete: " + str(result.get("error", "token cap")))
                    reference = tokens(case["text"])
                    actual = tokens(result.get("text", ""))
                    errors = edit_distance(reference, actual)
                    row = {"id": case["id"], "language": case["language"], "reference_words": len(reference), "word_errors": errors, "wer": errors/max(1,len(reference)), "duration": case["duration"], "wall_seconds": round(time.monotonic()-began,3), "response": result}
                    results.append(row)
                    (args.output / f"{engine}-results.json").write_text(json.dumps({"ready": ready, "cases": results}, ensure_ascii=False, indent=2) + "\n")
                    print(json.dumps({"engine": engine, "case": case["id"], "errors": errors, "words": len(reference), "seconds": row["wall_seconds"]}), flush=True)
                process.stdin.close()
                process.wait(timeout=15)
            except Exception as error:
                resource["failure"] = str(error)
                print(json.dumps({"engine": engine, "failure": str(error)}), flush=True)
            finally:
                stop(process)
                reading.join(timeout=2)
                resource.update(status="exited", exit_code=process.returncode, elapsed_seconds=round(time.monotonic()-started,3))
                resource_path.write_text(json.dumps(resource, indent=2) + "\n")
        total_words = sum(c["reference_words"] for c in results)
        total_errors = sum(c["word_errors"] for c in results)
        summary = {"engine":engine,"completed_cases":len(results),"declared_cases":len(corpus["cases"]),"words":total_words,"errors":total_errors,"wer":total_errors/max(1,total_words),"resource":resource}
        overall.append(summary)
        (args.output/"native-summary.json").write_text(json.dumps(overall,indent=2)+"\n")


if __name__ == "__main__":
    main()
