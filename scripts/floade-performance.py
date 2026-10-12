"""Read experimental RustDesk telemetry as JSON without controlling its UI."""
import argparse
import json
import os
import time
from pathlib import Path


def read_performance(log_path: Path):
    sessions = {}
    if log_path.is_file():
        with log_path.open("rb") as stream:
            stream.seek(max(0, log_path.stat().st_size - 512 * 1024))
            lines = stream.read().decode("utf-8", errors="replace").splitlines()
        decoder = json.JSONDecoder()
        for line in lines:
            prefix, marker, payload = line.partition("floade_perf ")
            if not marker:
                continue
            try:
                value, _ = decoder.raw_decode(payload)
            except (json.JSONDecodeError, ValueError):
                continue
            if isinstance(value, dict) and value.get("schema") == 1:
                value["log_timestamp"] = " ".join(prefix.split("[", 1)[-1].split(" ", 2)[:2])
                sample_time = value.get("sample_unix_ms")
                if isinstance(sample_time, (int, float)):
                    value["age_seconds"] = round(max(0, time.time() - sample_time / 1000), 2)
                    value["fresh"] = value["age_seconds"] <= 15
                else:
                    value["fresh"] = False
                sessions[str(value.get("session"))] = value
    return {
        "schema": 1,
        "available": bool(sessions),
        "samples": list(sessions.values()),
        "note": "Samples are historical; check log_timestamp for freshness.",
    }


def default_log(profile: str):
    directory = Path(os.environ.get("APPDATA", ".")) / profile / "log"
    candidates = [directory / "rustdesk_rCURRENT.log", directory / "flutter_ffi/rustdesk_rCURRENT.log"]
    existing = [path for path in candidates if path.is_file()]
    return max(existing, key=lambda path: path.stat().st_mtime) if existing else candidates[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path)
    parser.add_argument("--test-profile", action="store_true")
    arguments = parser.parse_args()
    if arguments.log is None:
        arguments.log = default_log("FloadeRustDesk" if arguments.test_profile else "RustDesk")
    print(json.dumps(read_performance(arguments.log), ensure_ascii=False))
