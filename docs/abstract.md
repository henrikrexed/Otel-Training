# Perform Hotday Proposal — Abstract

**Working title:** Production-Grade OpenTelemetry: Controlling the Cost and Quality of Observability — A 3-Hour Hands-On Training

**Alt title:** Observability You Can Afford — Cost, Control & Quality with OpenTelemetry and Dynatrace

> Title reworked per board feedback (2026-09-15): "Beyond the Honeymoon" dropped in favour of a business framing focused on cost and quality. The book of that name remains the source reference.

**Format:** 3-hour instructor-led hands-on lab (Hotday)
**Level:** Intermediate — attendees have deployed or tinkered with OpenTelemetry; now they run it for real.
**Based on:** the upcoming book *Beyond the Honeymoon: OpenTelemetry at Enterprise Scale* and the open-source [Perform-Hackathon-2026](https://github.com/dynatrace-oss/Perform-Hackathon-2026) application.

---

## Abstract (draft, ~200 words)

Getting one OpenTelemetry span into a dashboard is easy. Running observability across a polyglot fleet — without the bill exploding, PII leaking into logs, or bad telemetry breaking your incident response — is the hard part, and it's where the money and the risk live.

In this hands-on training we take a deliberately broken application — the Vegas Casino from the Perform Hackathon — from broken, expensive, ungoverned telemetry to a production-grade pipeline in three hours. First we fix it: core principles, signals and context propagation, resource semantics, and declarative SDK configuration. Then we make the collector your control point with BindPlane and turn to what actually matters at scale: **controlling cost** (taming metric cardinality, redacting PII from logs, applying tail-based sampling), **allocating and detecting abnormal ingestion cost**, and **guarding telemetry quality on every release** with Weaver and GitHub Actions. Every module ends with a visible win in Dynatrace.

This training is based on the upcoming book *Beyond the Honeymoon: OpenTelemetry at Enterprise Scale* and its enterprise readiness checklist. You'll leave with the lab repository, working configurations you wrote yourself, and a mental model of what "production-grade OTel" actually means.

Everything runs in a GitHub Codespace: bring a laptop, a GitHub account, and curiosity. No local setup required.

---

## Attendee takeaways

- Read and write OTel SDK **declarative configuration** (`otel-config.yaml`, file-based — not env-var soup)
- Reason about **sampling** as a cost/fidelity strategy, not a knob
- Design, validate, and roll out **collector pipelines with BindPlane**
- Recognize the failure modes of OTel at scale — and know the fixes

## Audience

Developers, SREs, and platform engineers who have seen OTel dashboards but now own (or are about to own) instrumentation and collectors across a fleet. Basic Kubernetes literacy assumed.
