#!/usr/bin/env python3
"""One bounded Xcode build with exact ownership and portable Metal resources."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "Build"
DERIVED = BUILD / "DerivedData"
PORTABLE = BUILD / "portable"
LOG = BUILD / "xcode-build.log"
LEDGER = ROOT / "worker-resources.json"
TIMEOUT_SECONDS = 1200


def timestamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def descendants(pid: int) -> list[int]:
    result = subprocess.run(["ps", "-Ao", "pid=,ppid="], capture_output=True, text=True, check=True)
    pairs = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if line.split()]
    found: list[int] = []
    pending = [pid]
    while pending:
        parent = pending.pop()
        children = [child for child, owner in pairs if owner == parent]
        found.extend(children)
        pending.extend(children)
    return found


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop_owned(process: subprocess.Popen) -> list[int]:
    children = descendants(process.pid)
    owned = list(reversed(children)) + [process.pid]
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and any(alive(pid) for pid in owned):
        process.poll()
        time.sleep(0.1)
    hung = [pid for pid in owned if alive(pid)]
    for pid in hung:
        # Only the exact descendants captured from this owned build are eligible.
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait(timeout=5)
    return [pid for pid in owned if alive(pid)]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def save_ledger(ledger: dict) -> None:
    LEDGER.write_text(json.dumps(ledger, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-scratch", action="store_true", help="Retain this owned DerivedData for active integration iterations")
    options = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    PORTABLE.mkdir(exist_ok=True)
    available = shutil.disk_usage("/System/Volumes/Data").free
    if available < 20 * 1024**3:
        raise RuntimeError("The bounded helper build requires at least 20 GiB of free disk.")
    subprocess.run(["xcodegen", "generate", "--spec", str(ROOT / "project.yml")], cwd=ROOT, check=True)
    resolved = ROOT / "ParrotASRWorker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    saved_resolved = ROOT / "Package.resolved"
    if saved_resolved.exists():
        resolved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(saved_resolved, resolved)
    command = [
        "xcodebuild", "-project", str(ROOT / "ParrotASRWorker.xcodeproj"),
        "-scheme", "ParrotASRWorker", "-configuration", "Release",
        "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(DERIVED), "-jobs", "2",
        "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build",
    ]
    if saved_resolved.exists():
        command.insert(-1, "-onlyUsePackageVersionsFromResolvedFile")
    opening_ps = subprocess.run(["ps", "-Ao", "pid=,ppid=,rss=,comm="], capture_output=True, text=True, check=True).stdout
    (BUILD / "preflight-processes.txt").write_text(opening_ps)
    previous = json.loads(LEDGER.read_text()) if LEDGER.exists() else {}
    if LOG.exists():
        shutil.copy2(LOG, BUILD / "xcode-build-previous.log")
    ledger = {
        "createdAt": timestamp(), "projectDirectory": str(ROOT), "supervisorPID": os.getpid(),
        "openingProcessCount": len(opening_ps.splitlines()), "freeDiskBytes": available,
        "resources": previous.get("resources", []),
        "artifacts": [{"path": str(DERIVED), "purpose": "bounded helper build", "disposition": "remove after portable output captured"},
                      {"path": str(PORTABLE), "purpose": "deliverable", "disposition": "keep"},
                      {"path": str(LOG), "purpose": "small build evidence", "disposition": "keep"}],
    }
    with LOG.open("wb") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        entry = {
            "kind": "xcode-build", "pid": process.pid, "command": command,
            "purpose": "compile portable native ASR worker and Metal resources",
            "startedAt": timestamp(), "stopCondition": f"build completion or {TIMEOUT_SECONDS}s timeout",
            "log": str(LOG), "status": "running",
        }
        ledger["resources"].append(entry)
        save_ledger(ledger)
        print(f"Owned Xcode build PID {process.pid}; log {LOG}", flush=True)
        try:
            code = process.wait(timeout=TIMEOUT_SECONDS)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            survivors = stop_owned(process)
            entry.update(status="terminated", finishedAt=timestamp(), verifiedExited=not survivors, survivingOwnedPIDs=survivors)
            save_ledger(ledger)
            raise
        entry.update(status="exited", exitCode=code, finishedAt=timestamp(), verifiedExited=not alive(process.pid))
        save_ledger(ledger)
    if code:
        print(f"Xcode build failed ({code}); inspect {LOG}", file=sys.stderr)
        return code

    products = DERIVED / "Build/Products/Release"
    binary = products / "ParrotASRWorker"
    if not binary.is_file():
        raise RuntimeError("Xcode reported success but the helper binary is missing.")
    metal_files = sorted(products.rglob("*.metallib"))
    shader = next((p for p in metal_files if p.name == "default.metallib" and "mlx-swift_Cmlx.bundle" in str(p)), None)
    if shader is None:
        shader = next((p for p in metal_files if p.name in ("mlx.metallib", "default.metallib")), None)
    if shader is None:
        raise RuntimeError("Xcode build produced no MLX metallib; the helper is not portable yet.")
    shutil.copy2(binary, PORTABLE / binary.name)
    shutil.copy2(shader, PORTABLE / "mlx.metallib")
    bundles = []
    for bundle in products.glob("*.bundle"):
        shutil.copytree(bundle, PORTABLE / bundle.name, dirs_exist_ok=True)
        bundles.append(bundle.name)
    app = PORTABLE / "ASRWorker.app"
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PORTABLE / binary.name, macos / binary.name)
    shutil.copy2(PORTABLE / "mlx.metallib", resources / "mlx.metallib")
    for name in bundles:
        shutil.copytree(PORTABLE / name, resources / name, dirs_exist_ok=True)
    with (app / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump({
            "CFBundleExecutable": "ParrotASRWorker", "CFBundleIdentifier": "com.nikita.parrot.asr-worker",
            "CFBundleName": "ASRWorker", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0", "LSBackgroundOnly": True,
        }, handle)
    manifest = {
        "builtAt": timestamp(), "sourceRevision": "dbe5eaac964e8257785f9d015c81f819a38016a8",
        "binary": str(PORTABLE / binary.name), "binarySHA256": digest(PORTABLE / binary.name),
        "metalSourcePath": str(shader), "metalSHA256": digest(PORTABLE / "mlx.metallib"),
        "resourceBundles": bundles,
        "unsignedNestedApp": str(app),
    }
    (PORTABLE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Preserve the actual resolved graph independently of disposable DerivedData.
    if resolved.exists():
        shutil.copy2(resolved, ROOT / "Package.resolved")
    if options.keep_scratch:
        ledger["artifacts"][0]["disposition"] = "retained for root-authorized integration iterations; remove after root acceptance"
    else:
        shutil.rmtree(DERIVED)
        ledger["artifacts"][0]["removedAt"] = timestamp()
    closing_ps = subprocess.run(["ps", "-Ao", "pid=,ppid=,rss=,comm="], capture_output=True, text=True, check=True).stdout
    ledger["closingProcessCount"] = len(closing_ps.splitlines())
    ledger["ownedHelpersRemaining"] = 0
    ledger["portableManifest"] = manifest
    save_ledger(ledger)
    scratch = "retained for integration" if options.keep_scratch else "removed"
    print(f"Portable helper ready: {PORTABLE}; owned build exited; DerivedData {scratch}.")
    return 0


if __name__ == "__main__":
    def requested_stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, requested_stop)
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
