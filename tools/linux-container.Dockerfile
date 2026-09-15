# Runtime-only qualification image. The caller records and runs the built immutable image ID.
FROM ubuntu:24.04
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install --yes --no-install-recommends libc6:i386 libgcc-s1:i386 libstdc++6:i386 \
    && rm -rf /var/lib/apt/lists/*
