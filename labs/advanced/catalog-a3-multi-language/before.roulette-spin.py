# BEFORE — roulette records a generic http_request span only.
#
# Unlike the slots service (Step 1), the Python roulette service never opens a
# domain span for the spin itself: there is no `casino.roulette.spin`, and none
# of the casino.* business attributes the Weaver registry (Step 2/3) guards. The
# money path is invisible to Dynatrace — you cannot slice roulette by
# game / outcome / payout the way you can slots.
#
# Reference "before" for catalog exercise A3 (multi-language instrumentation).

import random

from opentelemetry_setup import add_http_attributes


class RouletteHandler:
    def _handle_spin(self, span=None):
        """Handle roulette spin — HTTP span only, no domain span."""
        if span:
            add_http_attributes(span, "POST", "/spin")

        data = self._read_body()
        bet_type = data.get("BetType")
        bet_amount = data.get("BetAmount", 0)

        # Draw + settle happen with NO span of their own. Nothing records the
        # outcome or payout as telemetry, so Dynatrace sees a bare HTTP call.
        winning_number = random.randint(0, 36)
        color = get_color(winning_number)
        payout = calculate_payout(bet_type, data.get("BetValue"), winning_number)

        self._send_json_response(
            {"winningNumber": winning_number, "color": color, "payout": payout}
        )
