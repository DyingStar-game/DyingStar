#!/bin/bash
#
# Exports the client with its shaders baked, on the runner host's GPU.
#
# The export compiles every shader the game's resources use (~650, SPIR-V: Vulkan on Linux and on Windows)
# into the game, but only when the editor runs on a real Vulkan device. A --headless editor has none and
# skips it without a word: players then compiled them all on their first launch, 7 s frames on a desktop
# GPU and "not responding" on weak PCs (2026-11-19). Lavapipe (Mesa's CPU Vulkan) crashes the editor
# right after its file scan, so a GPU is needed.
#
# On dyingstar-runners the steps run in the `runner` container, which has no /dev/dri; its Docker daemon
# (the privileged `dind` sidecar) has the host's Intel UHD 770, and both share /home/runner/_work. So the
# export runs in a container started through that daemon (tools/ci/bake/Dockerfile), with the GPU, the
# workspace and copies of the editor and its templates under $RUNNER_TEMP. Without a GPU there (no Docker,
# no device, only a CPU Vulkan), it exports headless as before, with a warning; with one, a bake that
# stored nothing fails the build.
#
# Usage: tools/ci/export_client.sh <preset> <output file>
#   GODOT_VERSION, GITHUB_WORKSPACE, RUNNER_TEMP, RUNNER_WORKSPACE   from the workflow (the folder above
#                  RUNNER_WORKSPACE, /home/runner/_work, is what the Docker daemon shares with us)
#   GODOT_DIR      the editor's folder (default: ~/godot/Godot_v<version>-stable_mono_linux_x86_64)
#   DOTNET_ROOT    the .NET SDK, under $RUNNER_TEMP (actions/setup-dotnet with DOTNET_INSTALL_DIR)
#   EXPORT_GPU_ARGS  the docker run arguments that give the container the GPU (default: the render node,
#                  for Mesa; "--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all" on a machine with NVIDIA's runtime)

set -uo pipefail

preset="${1:?usage: export_client.sh <preset> <output file>}"
output="${2:?usage: export_client.sh <preset> <output file>}"
godot_dir="${GODOT_DIR:-$HOME/godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64}"
godot_bin="Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64"
templates="$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable.mono.double"
device=/dev/dri/renderD128
read -r -a gpu_args <<< "${EXPORT_GPU_ARGS:---device $device}"
shared="$(dirname "$RUNNER_WORKSPACE")"
image=dyingstar-export-bake
stage="$RUNNER_TEMP/export-bake"
log="$RUNNER_TEMP/export-$(basename "$output").log"
# A baked export stores ~200 of these; a headless one none.
min_baked=100

export_headless() {
    echo "::warning::$1: exporting headless, the shaders are NOT baked"
    "$godot_dir/$godot_bin" --headless --path "$GITHUB_WORKSPACE" --verbose \
        --export-release "$preset" "$output" 2>&1 | tee "$log"
    exit "${PIPESTATUS[0]}"
}

docker info > /dev/null 2>&1 || export_headless "No Docker daemon on this runner"
docker build -q -t "$image" "$GITHUB_WORKSPACE/tools/ci/bake" > /dev/null \
    || export_headless "Could not build the export image"
gpu=$(docker run --rm "${gpu_args[@]}" "$image" vulkaninfo --summary 2> /dev/null \
    | grep -E "deviceName|deviceType" | tr -s ' ')
echo "Vulkan devices seen with ${gpu_args[*]}:"
echo "$gpu"
grep -qE "PHYSICAL_DEVICE_TYPE_(INTEGRATED|DISCRETE)_GPU" <<< "$gpu" \
    || export_headless "No Vulkan GPU in the container (${gpu_args[*]})"

# What the container sees of the runner: only $shared (the workspace and $RUNNER_TEMP).
rm -rf "$stage"
mkdir -p "$stage/home/.local/share/godot/export_templates"
cp -a "$godot_dir" "$stage/godot"
cp -a "$templates" "$stage/home/.local/share/godot/export_templates/"
dotnet_root="${DOTNET_ROOT:-$RUNNER_TEMP/dotnet}"

docker run --rm "${gpu_args[@]}" -u "$(id -u):$(id -g)" \
    -v "$shared:$shared" -w "$GITHUB_WORKSPACE" \
    -e HOME="$stage/home" \
    -e GODOT_SHARP_NUPKGS="$stage/godot/GodotSharp/Tools/nupkgs" \
    -e DOTNET_ROOT="$dotnet_root" -e PATH="$dotnet_root:/usr/local/bin:/usr/bin:/bin" \
    -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
    "$image" bash -c '
        # As a non-root user Xvfb cannot make /tmp/.X11-unix: it listens on the abstract socket only.
        Xvfb :99 -screen 0 1280x720x24 -nolisten tcp 2> /dev/null &
        export DISPLAY=:99
        sleep 3
        "$0" --display-driver x11 --rendering-driver vulkan --path "$1" --verbose --export-release "$2" "$3"
    ' "$stage/godot/$godot_bin" "$GITHUB_WORKSPACE" "$preset" "$output" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
rm -rf "$stage"

baked=$(grep -cE "Storing File: res://\.godot/shader_cache/.*\.vulkan\.cache" "$log")
echo "Baked shader files in the export: $baked"
if [ "$status" -ne 0 ]; then
    echo "::error::The export on the GPU failed (exit code $status)"
    exit "$status"
fi
if [ "$baked" -lt "$min_baked" ]; then
    echo "::error::The export ran on the GPU but stored $baked baked shader files (~200 expected)"
    exit 1
fi
