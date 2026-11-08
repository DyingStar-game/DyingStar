"""Run two independent Godot peers concurrently; compare every checkpoint hash and final bytes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    destination = Path(args.output).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    project = Path(args.project).resolve()
    source = Path(__file__).resolve().parents[2]
    existing_project = project / "project.godot"
    if project == source or (existing_project.exists() and
            'config/name="DyingStarLavaReplay"' not in existing_project.read_text(encoding="utf-8-sig")):
        raise ValueError("Choose an empty replay directory, not the game or another existing project")
    for relative in ("scenes/planet/lava/lava_fixed_core.gd",
                     "scenes/planet/lava/lava_tick_job.gd",
                     "scenes/planet/lava/viscous_lava_solver.gd",
                     "test/lava/test_solver.gd", "test/lava/replay.gd"):
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="DyingStarLavaReplay"\n', encoding="utf-8")
    (project / "user-data").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["APPDATA"] = str(project / "user-data")
    env["LOCALAPPDATA"] = env["APPDATA"]
    with (destination / "unit-console.log").open("w", encoding="utf-8") as log:
        subprocess.run([args.godot, "--headless", "--path", str(project),
                        "--log-file", str(destination / "unit-engine.log"),
                        "--script", "res://test/lava/test_solver.gd"],
                       check=True, timeout=60, stdout=log, stderr=subprocess.STDOUT, env=env,
                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    children = []
    logs = []
    try:
        for role in ("server", "client"):
            output = destination / f"{role}.json"
            log = (destination / f"{role}-console.log").open("w", encoding="utf-8")
            logs.append(log)
            command = [args.godot, "--headless", "--path", str(project),
                       "--log-file", str(destination / f"{role}-engine.log"),
                       "--script", "res://test/lava/replay.gd", "--",
                       f"--role={role}", f"--output={output}"]
            children.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                env=env, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0))
        for child in children:
            if child.wait(timeout=60) != 0:
                raise RuntimeError("Godot replay failed; see console logs")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        for log in logs:
            log.close()
    server = json.loads((destination / "server.json").read_text(encoding="utf-8"))
    client = json.loads((destination / "client.json").read_text(encoding="utf-8"))
    if server["hashes"] != client["hashes"]:
        raise RuntimeError("A checkpoint hash differs between server and client")
    if (destination / "server.bin").read_bytes() != (destination / "client.bin").read_bytes():
        raise RuntimeError("Canonical binary states differ")
    report = {"concurrent_processes": 2, "ticks_per_peer": server["ticks"],
              "matching_checkpoints": len(server["hashes"]), "binary_identical": True,
              "final_sha256": server["final_sha256"], "os": server["os"],
              "engine": server["engine"], "server_frame_batches": server["frame_batches"],
              "client_frame_batches": client["frame_batches"]}
    (destination / "comparison.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
