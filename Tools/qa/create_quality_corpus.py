#!/usr/bin/env python3
"""Render the declared references with installed macOS voices, without capture."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for item in spec["cases"]:
        parts = item.get("parts", [{"voice": item.get("voice"), "text": item.get("text")}])
        with tempfile.TemporaryDirectory(prefix="ParrotQuality-", dir=args.output) as temporary:
            temporary = Path(temporary)
            audio_inputs = []
            for index, part in enumerate(parts):
                text = temporary / f"text-{index}.txt"
                text.write_text(part["text"])
                audio = temporary / f"part-{index}.aiff"
                subprocess.run(["/usr/bin/say", "-v", part["voice"], "-r", "165", "-f", str(text), "-o", str(audio)], check=True, timeout=60)
                audio_inputs.append(audio)
            destination = args.output / f"{item['id']}.wav"
            command = ["/opt/homebrew/bin/ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
            for audio in audio_inputs:
                command += ["-i", str(audio)]
            if len(audio_inputs) > 1:
                chain = "".join(f"[{i}:a]" for i in range(len(audio_inputs)))
                command += ["-filter_complex", f"{chain}concat=n={len(audio_inputs)}:v=0:a=1[out]", "-map", "[out]"]
            command += ["-ar", "16000", "-ac", "1", "-c:a", "pcm_f32le", str(destination)]
            subprocess.run(command, check=True, timeout=60)
        duration = float(subprocess.check_output(["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(destination)], text=True, timeout=10))
        result = {"id": item["id"], "language": item["language"], "text": " ".join(p["text"] for p in parts), "file": destination.name, "duration": duration, "bytes": destination.stat().st_size, "sha256": hashlib.file_digest(destination.open("rb"), "sha256").hexdigest()}
        results.append(result)
        print(json.dumps({"case": item["id"], "duration": duration}), flush=True)
    (args.output / "manifest.json").write_text(json.dumps({"version": spec["version"], "acceptance": spec["acceptance"], "cases": results}, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
