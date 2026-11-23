# Weaver policy pack — extra regression guards beyond the built-in registry checks.
# Run with:  weaver registry check -r registry --policy weaver-policies/casino_policies.rego
#
# Weaver evaluates these Rego rules against each group; any `deny` with a message fails the
# check (non-zero exit → CI red). These encode the casino's cardinality + naming contracts.
package otel_policy_violations

import rego.v1

# 1. Every casino.* attribute must be snake_case dotted (catches casino.betAmount drift).
deny contains msg if {
	some group in input.groups
	some attr in group.attributes
	startswith(attr.id, "casino.")
	regex.match(`[A-Z]`, attr.id)
	msg := sprintf("casino attribute '%s' must be snake_case (no camelCase)", [attr.id])
}

# 2. The casino.payout.total metric must NOT be dimensioned by any *.id attribute
#    (high-cardinality guard — see Step 4).
deny contains msg if {
	some group in input.groups
	group.metric_name == "casino.payout.total"
	some attr in group.attributes
	endswith(attr.ref, ".id")
	msg := sprintf("metric casino.payout.total must not carry high-cardinality dimension '%s'", [attr.ref])
}
