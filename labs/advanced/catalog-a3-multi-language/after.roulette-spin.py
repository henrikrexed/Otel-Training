# AFTER — the Step-1 span pattern, ported to Python.
#
# An explicit `casino.roulette.spin` child span wraps the draw + payout
# settlement and carries the SAME casino.* attributes the slots service sets in
# Step 1 (JavaScript) — proving the semantic-convention contract crosses SDKs and
# languages. Attribute names match the Weaver registry in
# labs/advanced/step2-weaver-semconv/ EXACTLY, so Step 3's weaver check guards
# roulette as well as slots, and both games answer the same DQL.
#
# Reference "after" for catalog exercise A3 (multi-language instrumentation).

import random

from opentelemetry import trace
from opentelemetry.trace import StatusCode

from opentelemetry_setup import add_http_attributes

# Same tracer-per-service shape as slots' `trace.getTracer('casino-slots', ...)`.
tracer = trace.get_tracer("casino-roulette", "2.1.0")


class RouletteHandler:
    def _handle_spin(self, span=None):
        """Handle roulette spin — domain span mirrors the slots Step-1 pattern."""
        if span:
            add_http_attributes(span, "POST", "/spin")

        data = self._read_body()
        bet_type = data.get("BetType")
        bet_amount = data.get("BetAmount", 0)

        # Domain span — a CHILD of the auto-instrumented http_request server span.
        with tracer.start_as_current_span("casino.roulette.spin") as spin:
            try:
                spin.set_attribute("casino.game.name", "roulette")
                spin.set_attribute("casino.bet.amount", bet_amount)

                winning_number = random.randint(0, 36)
                color = get_color(winning_number)
                payout = calculate_payout(bet_type, data.get("BetValue"), winning_number)
                outcome = "win" if payout > 0 else "lose"

                spin.set_attribute("casino.outcome", outcome)  # win | lose
                spin.set_attribute("casino.payout.amount", payout)
                if payout >= bet_amount * 30:  # 36x straight-up ~ jackpot
                    spin.add_event("jackpot", {"casino.payout.amount": payout})

                self._send_json_response(
                    {"winningNumber": winning_number, "color": color, "payout": payout}
                )
            except Exception as err:  # keep the span honest on failure
                spin.set_status(StatusCode.ERROR, str(err))
                spin.record_exception(err)
                raise
