#!/usr/bin/env python3
"""Fetch pinned public speech weights, checking Git/LFS content identities."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import urllib.request


def download_file(base, entry, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected_size = entry["size"]
    expected_sha = (entry.get("lfs") or {}).get("sha256")
    if destination.exists() and destination.stat().st_size == expected_size:
        if expected_sha and hashlib.file_digest(destination.open("rb"), "sha256").hexdigest() == expected_sha:
            return
        if not expected_sha:
            data = destination.read_bytes()
            git_sha = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
            if git_sha == entry["blobId"]:
                return
    temporary = destination.with_name(destination.name + ".partial")
    request = urllib.request.Request(base + entry["rfilename"], headers={"User-Agent": "Parrot-local-validation/1"})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
        digest = hashlib.sha256()
        received = 0
        last_report = started
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
            digest.update(chunk)
            received += len(chunk)
            if time.monotonic() - started > 900:
                raise TimeoutError("Pinned model file exceeded its bounded download time")
            if time.monotonic() - last_report > 15:
                print(json.dumps({"file": entry["rfilename"], "received": received, "expected": expected_size}), flush=True)
                last_report = time.monotonic()
    if received != expected_size:
        raise ValueError(f"File size mismatch for {entry['rfilename']}")
    if expected_sha:
        if digest.hexdigest() != expected_sha:
            raise ValueError(f"Weight SHA256 mismatch for {entry['rfilename']}")
    else:
        data = temporary.read_bytes()
        if hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest() != entry["blobId"]:
            raise ValueError(f"Git object mismatch for {entry['rfilename']}")
    temporary.replace(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(args.destination).free < 20 * 1024**3:
        raise RuntimeError("Insufficient disk headroom for a bounded model comparison")
    metadata = {item["model"]: item for item in json.loads(args.metadata.read_text()) if "sha" in item}
    choices = {
        "qwen": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "moss": "OpenMOSS-Team/MOSS-Transcribe-Diarize",
    }
    report = []
    for engine, name in choices.items():
        model = metadata[name]
        destination = args.destination / engine
        files = [item for item in model["files"] if item["rfilename"].endswith((".json", ".txt", ".safetensors"))]
        base = f"https://huggingface.co/{name}/resolve/{model['sha']}/"
        manifest = {"engine": engine, "modelID": name, "revision": model["sha"], "files": []}
        print(json.dumps({"engine": engine, "revision": model["sha"], "bytes": sum(f["size"] for f in files)}), flush=True)
        for entry in files:
            target = destination / entry["rfilename"]
            download_file(base, entry, target)
            manifest["files"].append({"name": entry["rfilename"], "bytes": target.stat().st_size, "sha256": hashlib.file_digest(target.open("rb"), "sha256").hexdigest()})
        (destination / "model-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        report.append(manifest)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"engine": engine, "verified_files": len(files)}), flush=True)


if __name__ == "__main__":
    main()
