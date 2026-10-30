"""Package the reviewed StarGrotte contribution without touching the real Git index.
Run: python tools/stargrot/package_develop.py --output <directory> [--base origin/develop]
No push, checkout, commit or merge. Existing native assets are never rewritten.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = {
    ".gitignore", "scenes/globals/chat_network.gd", "scenes/globals/game_orchestrator.gd",
    "scenes/globals/globals.gd", "scenes/planet/planet_chunk.gd", "scenes/planet/planet_data.gd",
    "scenes/planet/planet_terrain.gd", "scenes/player/player.gd", "scenes/player/player_server.gd",
    "tools/observability/obs.gd", "addons/dyingstar/dyingstar.gd", "export_presets.cfg",
    "tools/native/NativeLibraryPin.cs", "scenes/systems/tarsis/tarsis_3.tscn", "assets/credits.json",
    "scenes/_universe/structures/dispenser/item_dispenser.gd",
}
REPORT = "STARGROT-PR-2026-10-28.md"
DOCS = {"README-STARGROT.md", "STARGROT-LIVRAISON-DEVELOP.md", "STARGROT-RELEASE-2026-10-24.md", REPORT,
        "STARGROT-REVUE-2026-10-28.md", "STARGROT-INTEGRATION-2026-10-28.md"}
VERSION = "0.9"
PREFIXES = ("tools/stargrot/", "levels/stargrot/", "scenes/planet/cave/", "test/stargrot/",
            "test/unit/test_stargrot", "test/unit/stargrot_fixture")
EXTENSIONS = {".gd", ".uid", ".cs", ".tres", ".tscn", ".gdshader", ".ps1", ".py"}
# Imported rock models and their Blender source ship whole (.glb, .import, manifest, .blend, .gdignore).
ASSETS = ("scenes/planet/cave/assets/", "assets_blender/stargrot/")


def git(*args, env=None):
    return subprocess.check_output(["git", *args], cwd=ROOT, env=env)


def included(name):
    return name in NATIVE or name in DOCS or name.startswith(ASSETS) or (
        name.startswith(PREFIXES) and Path(name).suffix in EXTENSIONS)


def verified_sources(base):
    proof_path = ROOT / ".stargrot-validation/passed.json"
    if not proof_path.exists():
        raise SystemExit("Verification evidence is missing. Run verify_develop.ps1 before packaging.")
    proof = json.loads(proof_path.read_text(encoding="utf-8-sig"))
    hashes = proof.get("sha256", {})
    if proof.get("base_develop", proof.get("commit")) != base or not hashes:
        raise SystemExit("Verification evidence does not identify this base and its source files. Run verify_develop.ps1.")
    for name, digest in hashes.items():
        if not (ROOT / name).is_file() or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise SystemExit("Source changed since verification: " + name)
    return proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base", default="origin/develop", help="Reviewed target revision for the complete contribution")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    base = git("rev-parse", args.base).decode().strip()
    git("merge-base", "--is-ancestor", base, "HEAD")
    dirty = set(git("diff", base, "--name-only").decode().splitlines())
    unknown = {name for name in dirty if not included(name)}
    if unknown:
        raise SystemExit("Review unrelated tracked changes before packaging: " + str(sorted(unknown)))
    additions = git("ls-files", "--others", "--exclude-standard").decode().splitlines()
    files = sorted(dirty | {name for name in additions if included(name)})
    proof = verified_sources(base)
    # Separate index: the user's staging area is untouched; the patch remains reviewable.
    with tempfile.TemporaryDirectory(prefix="stargrot-package-") as temp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / "index"))
        git("read-tree", base, env=env)
        git("add", "--", *files, env=env)
        patch = git("diff", "--cached", "--binary", base, env=env)
        patch_path = output / f"StarGrotte-{VERSION}-develop.patch"
        patch_path.write_bytes(patch)
        git("read-tree", base, env=env)
        git("apply", "--check", "--cached", str(patch_path), env=env)
    manifest = {"base_develop": base, "files": files, "patch_applies_to_clean_base": True,
        "sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files},
        "patch_sha256": hashlib.sha256(patch).hexdigest()}
    manifest["verification"] = proof
    manifest_path = output / f"StarGrotte-{VERSION}-livraison.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    archive = output / f"StarGrotte-{VERSION}-pour-develop.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        bundle.write(patch_path, patch_path.name)
        bundle.write(manifest_path, manifest_path.name)
        bundle.write(ROOT / "STARGROT-LIVRAISON-DEVELOP.md", "LIRE-AVANT-INTEGRATION.md")
        bundle.write(ROOT / REPORT, "BILAN-INTEGRATION.md")
    with zipfile.ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        assert bundle.read(patch_path.name) == patch
    print(json.dumps({"archive": str(archive), "files": len(files), "base": base,
                      "patch_checked": True, "bytes": archive.stat().st_size}))


if __name__ == "__main__":
    main()
