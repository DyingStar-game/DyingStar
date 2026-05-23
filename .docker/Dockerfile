############################################
# ----------- BUILDER STAGE ----------------
############################################
FROM debian:trixie-slim AS builder

ENV GODOT_VERSION=4.6.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    unzip \
    git \
    ca-certificates \
    libstdc++6 \
    libicu76 \
    fontconfig \
    libtbbmalloc2 \
    && rm -rf /var/lib/apt/lists/*

# Microsoft repo + .NET SDK (builder only)
RUN wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        dotnet-sdk-9.0 \
    && rm -rf /var/lib/apt/lists/*

# Godot
WORKDIR /godot
RUN wget https://github.com/DyingStar-game/godotandaddons/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64.zip && \
    unzip Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64.zip && \
    rm Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64.zip && \
    chmod +x Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64

# Export templates
RUN wget https://github.com/DyingStar-game/godotandaddons/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_mono_export_templates.tpz && \
    unzip Godot_v${GODOT_VERSION}-stable_mono_export_templates.tpz && \
    rm Godot_v${GODOT_VERSION}-stable_mono_export_templates.tpz && \
    rm templates/windows* && \
    mkdir -p /root/.local/share/godot/export_templates/${GODOT_VERSION}.stable.mono.double && \
    mv templates/linux_debug.x86_64 \
       /root/.local/share/godot/export_templates/${GODOT_VERSION}.stable.mono.double/linux_debug.x86_64 && \
    mv templates/linux_release.x86_64 \
       /root/.local/share/godot/export_templates/${GODOT_VERSION}.stable.mono.double/linux_release.x86_64

# Project build
WORKDIR /build
COPY . .

# ── Restore chunk cache + import + prebake (single layer) ───────
# Combining these three steps avoids storing the 10 GiB chunk_cache
# move as a separate layer (saves ~10 GiB during build).
#   1. Restore prebaked chunk cache if provided in build context
#      (cp -r ~/.local/share/godot/app_userdata/DyingStar/chunk_cache chunk_cache)
#   2. Import project (generates .godot/imported/)
#   3. Prebake server collision shapes for all export-level HEALPix chunks
# RUN if [ -d /build/chunk_cache ]; then \
#       mkdir -p /root/.local/share/godot/app_userdata/DyingStar && \
#       mv -f /build/chunk_cache /root/.local/share/godot/app_userdata/DyingStar/chunk_cache && \
#       echo "[Docker] Restored chunk_cache from build context"; \
#     else \
#       echo "[Docker] No chunk_cache in build context — will generate from scratch"; \
#     fi \
#     && /godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64 \
#       --headless --path /build --import \
#     && /godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64 \
#       --headless --path /build --script res://tools/prebake_server_chunks.gd

# ── Export server binary + cleanup (single layer) ───────────────
# chunk_cache is placed in /cache/ (separate from /out/) so the
# runtime stage can COPY each to its final destination without an
# intermediate mv that would double the 10 GiB across layers.
WORKDIR /out

# ── Pre-export configuration ─────────────────────────────────────────────────
# 1. Rewrite NuGet.Config to add the bundled double-precision GodotSharp nupkgs.
#    The repo NuGet.Config only has nuget.org, which does not carry the custom
#    Godot.NET.Sdk/GodotSharp double-precision packages.  Without this, Godot's
#    internal `dotnet publish` (invoked automatically by --export-release via
#    GodotTools) cannot resolve the SDK and exits with code 145 — producing no
#    .NET assemblies dir and a server that crashes at runtime.
#    This mirrors the "Configure NuGet for double-precision GodotSharp" step in
#    build-client.yaml.
#
# 2. Strip the linux GDExtension entry from godot-livekit so it is not loaded
#    during the headless import / export passes.  The .so requires libpipewire,
#    libX11, and more display libs that are intentionally absent in the builder
#    image.  A load failure prevents LiveKit GDScript types from being registered,
#    which causes server/client.gd to fail with parse errors that propagate into
#    the .NET build.  The addon is already excluded from the server PCK via
#    exclude_filter in export_presets.cfg, so the shipped binary is unaffected.
#
# 3. Purge any cached Godot NuGet packages that may have been pulled from
#    nuget.org in a previous (cached) build layer.  Those are single-precision
#    variants and would cause a Vector3/Transform3D layout mismatch at runtime.
RUN NUPKGS="/godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/GodotSharp/Tools/nupkgs" \
    && printf '<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <clear />\n    <add key="godot-double-precision" value="%s" />\n    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />\n  </packageSources>\n  <packageSourceMapping>\n    <packageSource key="godot-double-precision">\n      <package pattern="Godot.*" />\n      <package pattern="GodotSharp*" />\n    </packageSource>\n    <packageSource key="nuget.org">\n      <package pattern="*" />\n    </packageSource>\n  </packageSourceMapping>\n</configuration>\n' "$NUPKGS" > /build/NuGet.Config \
    && sed -i '/^linux/d' /build/addons/godot-livekit/godot-livekit.gdextension \
    && rm -rf /root/.nuget/packages/godotsharp \
              /root/.nuget/packages/godotsharpeditor \
              /root/.nuget/packages/godot.net.sdk \
              /root/.nuget/packages/godot.sourcegenerators

# ── Import + export ───────────────────────────────────────────────────────────
# --import  : generates .godot/imported/ including CSV → .translation files.
#             Runs with || true because obs.gd autoload will fail (it loads a
#             C# class via load() at class-init time, but the C# assemblies do
#             not exist yet).  Resource importing is independent of autoloads
#             so translation files are still generated.
# --export-release : compiles C# via `dotnet publish` (now using the correct
#             NuGet source above), exports the PCK, and writes the binary + the
#             data_DyingStar_linuxbsd_x86_64/ .NET assemblies directory.
# Verification fails the build loudly if the .NET assemblies dir is absent,
# so we never ship a broken image again.
RUN /godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64 \
      --headless --path /build --import || true \
    && /godot/Godot_v${GODOT_VERSION}-stable_mono_linux_x86_64/Godot_v${GODOT_VERSION}-stable_mono_linux.x86_64 \
        --headless \
        --path /build \
        --verbose \
        --export-release dedicated_server /out/dyingstar_server.x86_64 \
    && cp /build/server.ini /out/server.ini \
    && (mv /root/.local/share/godot/app_userdata/DyingStar/chunk_cache /cache 2>/dev/null || mkdir -p /cache) \
    && echo "[Docker] Verifying export outputs..." \
    && test -f /out/dyingstar_server.x86_64 \
    && test -d /out/data_DyingStar_linuxbsd_x86_64 \
    && ls /out/data_DyingStar_linuxbsd_x86_64/ | head -20 \
    && rm -rf /godot /build /root/.local/share/godot \
    && ls -la /out/ /cache/


############################################
# ----------- RUNTIME STAGE ----------------
############################################
FROM debian:trixie-slim

# .NET runtime is required at runtime: the Godot Mono binary loads the CLR on
# startup to execute C# assemblies. Without it the process crashes (SIGSEGV/139).
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && wget https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb \
    && dpkg -i packages-microsoft-prod.deb \
    && rm packages-microsoft-prod.deb \
    && apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 \
        libicu76 \
        libtbbmalloc2 \
        dotnet-runtime-9.0 \
        gdb \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Server binary, PCK, .NET assemblies, server.ini (small — no chunk_cache).
COPY --from=builder /out/ .
# chunk_cache goes directly to Godot user:// path.
# Avoids duplicating 10+ GiB across two layers (COPY + mv).
COPY --from=builder /cache/ /root/.local/share/godot/app_userdata/DyingStar/chunk_cache/

# Entrypoint wrapper: runs the server under gdb so any crash (SIGSEGV/139)
# prints a full backtrace of all threads to stdout instead of dying silently.
# Set DEBUG_GDB=0 in the container env to bypass gdb (production default).
COPY .docker/run-server.sh /app/run-server.sh
RUN chmod +x dyingstar_server.x86_64 /app/run-server.sh && ls -la /app/

# .NET diagnostics: enable mini-dumps on managed crashes (written to /tmp).
ENV DOTNET_DbgEnableMiniDump=1 \
    DOTNET_DbgMiniDumpType=2 \
    DOTNET_DbgMiniDumpName=/tmp/coredump.%d.%t \
    DOTNET_EnableDiagnostics=1

CMD ["/app/run-server.sh"]
