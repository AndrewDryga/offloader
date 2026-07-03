/* One honest flourish: the cost ledger ticks the last stretch up to its resting
   value shortly after load — the same query, still being billed. The HTML seeds the
   *start* of that stretch (910,000 × $0.012 = $10,920, internally consistent), so
   there's never a downward flash. Reduced motion → jump straight to the resting
   values (the ones the aria-label and the pricing ledger quote). No JS → the seed
   stands, still consistent and labeled illustrative. */
(function () {
  "use strict";
  var calls = document.querySelector(".js-count");
  var cost = document.querySelector(".js-cost");
  if (!calls || !cost) return;

  var callsTo = +calls.dataset.to;              // 1,000,000
  var costTo = +cost.dataset.to;                //    12,000
  var callsFrom = Math.round(callsTo * 0.91);   // start high — never reads as "few"
  var costFrom = Math.round(costTo * 0.91);

  var nfInt = new Intl.NumberFormat("en-US");
  var nfUsd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });

  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) {
    // No animation — rest immediately at the values the aria-label and pricing quote.
    calls.textContent = nfInt.format(callsTo);
    cost.textContent = nfUsd.format(costTo);
    return;
  }

  // Quadratic ease-out: brisk enough to notice, with a long soft settle — the ledger
  // should read as a meter still running, not a slot machine snapping to its total.
  function easeOut(t) { return 1 - (1 - t) * (1 - t); }

  function run() {
    var dur = 3800, start = null;
    function frame(ts) {
      if (start === null) start = ts;
      var t = Math.min((ts - start) / dur, 1);
      var e = easeOut(t);
      calls.textContent = nfInt.format(Math.round(callsFrom + (callsTo - callsFrom) * e));
      cost.textContent = nfUsd.format(Math.round(costFrom + (costTo - costFrom) * e));
      if (t < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  // The ledger sits in the hero (above the fold): start shortly after load.
  calls.textContent = nfInt.format(callsFrom);
  cost.textContent = nfUsd.format(costFrom);
  setTimeout(run, 450);
})();
