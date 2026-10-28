# OTel Training — Perform Hotday devcontainer base image.
# Tools are baked into the image so GitHub Codespaces prebuilds cache them and
# cold start stays fast. The kind *cluster* is created at container start
# (postCreate) because it needs the Docker daemon, which only runs at runtime.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

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
RUN KUBECTL_VERSION="${KUBECTL_VERSION}" \
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

USER vscode
