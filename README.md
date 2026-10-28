# OTel Training — Hotday (Dynatrace Perform)

3-hour hands-on OpenTelemetry training: BindPlane collector configuration,
declarative SDK configuration (sampling, exporters...), OTel Enterprise Book companion labs.

Project: Hotday otel beyon HoneyMoon (ISI-4025)

## Deliverables

- [`docs/abstract.md`](docs/abstract.md) — Perform session abstract (working title, takeaways, audience)
- [`docs/training-structure.md`](docs/training-structure.md) — full 3-hour structure: agenda, module-by-module labs, planted-defect inventory, logistics
- [`docs/attendee-guide-v1.md`](docs/attendee-guide-v1.md) — attendee-facing lab guide v1 (M0–M4): step-by-step commands, Dynatrace checks, troubleshooting (ISI-4031)
- [`observability/`](observability/) — OTel collection topology for the kind cluster: OTel Operator + DaemonSet logs collector + gateway collector (k8sattributes / cumulativetodelta / Dynatrace OTLP export) with offline `validate.sh` (ISI-6792)
