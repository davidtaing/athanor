# Multi-stage build for athanor-runner, the ephemeral Go runner (ADR 0003).
# The Runner *is* the sandbox: one container executes exactly one Job, then is
# destroyed by the Provisioner. The image carries the binary plus a shell and
# git for running a Job's Steps.

# Canonical Go version pin lives in runner/go.mod (toolchain directive); keep
# this in sync on upgrades. .tool-versions golang line is asdf convenience.
ARG GO_VERSION=1.26.4
ARG DEBIAN_VERSION=bookworm-20260518

ARG BUILDER_IMAGE="golang:${GO_VERSION}-bookworm"
ARG RUNTIME_IMAGE="debian:${DEBIAN_VERSION}-slim"

FROM ${BUILDER_IMAGE} AS builder

WORKDIR /src

# Cache modules
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Static binary so the runtime image needs no Go toolchain or libc surprises.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/athanor-runner .

FROM ${RUNTIME_IMAGE} AS runtime

# Steps run through /bin/sh; git + CA certs let a Job check out its repo.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/athanor-runner /usr/local/bin/athanor-runner

# Non-root by default; the Job runs as this user inside the sandbox.
RUN useradd --create-home --uid 1000 runner
USER runner
WORKDIR /home/runner

ENTRYPOINT ["/usr/local/bin/athanor-runner"]
