# Perform Hotday Proposal — Abstract

**Working title:** Beyond the Honeymoon: OpenTelemetry in Practice — A 3-Hour Hands-On Training

**Alt title:** OpenTelemetry Beyond the Honeymoon: From First Span to Production Pipeline

**Format:** 3-hour instructor-led hands-on lab (Hotday)
**Level:** Intermediate — attendees have deployed or tinkered with OpenTelemetry; now they run it for real.
**Based on:** the upcoming book *Beyond the Honeymoon: OpenTelemetry at Enterprise Scale* and the open-source [Perform-Hackathon-2026](https://github.com/dynatrace-oss/Perform-Hackathon-2026) application.

---

## Abstract (draft, ~200 words)

Your first OpenTelemetry span is a honeymoon: one service, one collector, one dashboard — and it just works. Then the polyglot microservices arrive, the bill lands, and the config sprawl begins.

In this hands-on training we fix a deliberately broken application — the Vegas Casino from the Perform Hackathon — and take its telemetry pipeline from broken to production-grade in three hours. Along the way you'll practice the core principles that matter at enterprise scale: signals and context propagation, resource semantics, and declarative SDK configuration (`otel-config.yaml` — samplers, batch processors, OTLP exporters). Then we make the collector your control point: processors, routing, tail-based sampling, and backpressure — configured, validated, and rolled out with BindPlane the way real fleets are managed. Every module ends with a visible win in Dynatrace.

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
