# The editor that exports the client with its shaders baked (tools/ci/export_client.sh): Mesa's Vulkan
# drivers for the host's GPU (passed with --device /dev/dri/renderD128), a virtual X display, and what
# the Godot editor and .NET (mounted from the runner) need. Ubuntu 24.04, like the runner image.
FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates libicu74 libssl3t64 \
      mesa-vulkan-drivers libvulkan1 vulkan-tools xvfb \
      libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 libxkbcommon0 \
      libgl1 libegl1 libfontconfig1 libasound2t64 libpulse0 libudev1 libdbus-1-3 libpipewire-0.3-0t64 \
    && rm -rf /var/lib/apt/lists/*
