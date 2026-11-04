# OTel Training — Perform Hotday devcontainer base image.
# Tools are baked into the image so GitHub Codespaces prebuilds cache them and
# cold start stays fast. The kind *cluster* is created at container start
# (postCreate) because it needs the Docker daemon, which only runs at runtime.
# The base image is multi-arch. We intentionally do NOT pin `--platform` on FROM
# so a native build on an Apple Silicon Mac produces an arm64 image (and amd64 on
# Codespaces / Intel). Forcing `--platform=linux/amd64` here would make kind run
# amd64 node containers under QEMU emulation on Apple Silicon → segfault (ISI-7044).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# BuildKit auto-populates these per-build; declaring them brings them into scope
# for the RUN steps below so the toolchain install follows the *target* platform
# (authoritative for `docker buildx build --platform …` cross builds) rather than
# a possibly-emulated `uname -m`. install-tools.sh prefers TARGETARCH/TARGETOS.
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETARCH
ARG TARGETOS

# Make the resolved platform loud: a cross/emulated build (BUILDPLATFORM differs
# from TARGETPLATFORM, e.g. an amd64 image built on an arm64 Mac) is the ISI-7044
# segfault trap, so surface it in the build log instead of failing silently.
RUN echo "==> building devcontainer image for TARGETPLATFORM=${TARGETPLATFORM:-<native>} on BUILDPLATFORM=${BUILDPLATFORM:-<native>}" \
 && if [ -n "${BUILDPLATFORM}" ] && [ -n "${TARGETPLATFORM}" ] && [ "${BUILDPLATFORM}" != "${TARGETPLATFORM}" ]; then \
      echo "WARN: cross-platform build (${BUILDPLATFORM} -> ${TARGETPLATFORM}). If the host is Apple Silicon and TARGETPLATFORM is linux/amd64, kind will run under QEMU and may segfault (ISI-7044). Build natively: drop any --platform=linux/amd64 override."; \
    fi

# Tool versions — overridable from devcontainer.json build args / Codespaces env.
# Pinned to match the kind node image (kind-config.yaml) to avoid version skew.
ARG KUBECTL_VERSION=v1.31.2
ARG HELM_VERSION=v3.16.4
ARG KIND_VERSION=v0.25.0
ARG ARGOCD_VERSION=v2.13.2
ARG YQ_VERSION=v4.44.6
ARG DTCTL_VERSION=v0.45.0
ARG DTCTL_REPO=Dynatrace/dtctl

# Base OS packages needed by the bootstrap + day-of labs.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git jq gnupg apt-transport-https bash-completion \
 && rm -rf /var/lib/apt/lists/*

# Install the Kubernetes/OTel toolchain. The script is idempotent and honours the
# *_VERSION env vars below, so it is reused verbatim by postStart for self-heal.
COPY bootstrap/install-tools.sh /usr/local/share/install-tools.sh
RUN TARGETARCH="${TARGETARCH}" \
    TARGETOS="${TARGETOS}" \
    KUBECTL_VERSION="${KUBECTL_VERSION}" \
    HELM_VERSION="${HELM_VERSION}" \
    KIND_VERSION="${KIND_VERSION}" \
    ARGOCD_VERSION="${ARGOCD_VERSION}" \
    YQ_VERSION="${YQ_VERSION}" \
    DTCTL_VERSION="${DTCTL_VERSION}" \
    DTCTL_REPO="${DTCTL_REPO}" \
    bash /usr/local/share/install-tools.sh \
 && kubectl version --client=true --output=yaml >/dev/null \
 && helm version --short \
 && kind version \
 && yq --version

# Shell completions for a smoother day-of experience.
RUN kubectl completion bash >/etc/bash_completion.d/kubectl \
 && helm completion bash  >/etc/bash_completion.d/helm \
 && echo 'alias k=kubectl' >>/etc/bash.bashrc \
 && echo 'complete -o default -F __start_kubectl k' >>/etc/bash.bashrc

# Record the arch this image was built for, so `docker inspect` / the verify
# script can confirm an attendee's image matches their host (ISI-7044).
LABEL org.opencontainers.image.title="otel-training-devcontainer" \
      org.opencontainers.image.source="https://github.com/henrikrexed/Otel-Training" \
      org.opencontainers.image.architecture="${TARGETARCH}"

USER vscode
