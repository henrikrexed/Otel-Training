# Step 5 — PII in logs: collector redaction → BindPlane escalation

**Concept:** the casino logs player email, credit-card PAN, and SSN. Shipping that to
Dynatrace is a compliance incident. Clean it at the collector first (regex), then — when
hand-rolled regex stops scaling — escalate to centrally managed redaction with **BindPlane
OP via the OTel Operator OpAMP bridge**.

## Before

The gateway exports logs verbatim. A player-service log line like
`charged player john.doe@example.com card 4111 1111 1111 1111 ssn 123-45-6789` lands in the
Dynatrace Log Viewer **with the PII intact**.

## After (collector redaction)

Apply the `redaction` + `transform/pii` processors
([`redaction-processor.yaml`](redaction-processor.yaml)) — wired into the logs pipeline in
the composed [`../gateway-advanced.yaml`](../gateway-advanced.yaml):

```bash
kubectl apply -f labs/advanced/gateway-advanced.yaml
```

The same line now arrives as
`charged player ***EMAIL_REDACTED*** card ***PAN_REDACTED*** ssn ***SSN_REDACTED***`.

## After (BindPlane escalation)

When regex-by-hand no longer scales, hand config to BindPlane OP over OpAMP —
see [`bindplane-opamp/`](bindplane-opamp/). The operator's OpAMP bridge pushes a central
"Mask Sensitive Data" config to the gateway, no manual YAML.

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 5](../VALIDATION.md#step-5--pii-redaction). PII leak scan
over the last hour (expect ZERO rows after the fix):

```dql
fetch logs, from: now() - 1h
| filter k8s.namespace.name == "casino"
| filter matchesPhrase(content, "@") or matchesValue(content, "*-**-****")
| filter matchesValue(content, "*@*.*")        // residual email shapes
| summarize leaks = count()
```

- **Before:** `leaks > 0` — raw email/PAN/SSN visible in the Log Viewer.
- **After (redaction):** `leaks == 0`; sampled lines show `***…_REDACTED***`.
- **After (BindPlane):** same clean result, now driven by the pushed BindPlane config; the
  OpAMPBridge reports healthy + effective-config in Dynatrace.
