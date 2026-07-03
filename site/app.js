/* One honest flourish: the cost ledger ticks the last stretch up to its resting
   value shortly after load — the same query, still being billed. Every visible
   frame already reads "a lot", and it settles on the round total. No motion
   preference (or no JS) → the final values already in the HTML simply stand. */
(function () {
  "use strict";
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) return;

  var calls = document.querySelector(".js-count");
  var cost = document.querySelector(".js-cost");
  if (!calls || !cost) return;

  var callsTo = +calls.dataset.to;              // 1,000,000
  var costTo = +cost.dataset.to;                //    12,000
  var callsFrom = Math.round(callsTo * 0.91);   // start high — never reads as "few"
  var costFrom = Math.round(costTo * 0.91);

  var nfInt = new Intl.NumberFormat("en-US");
  var nfUsd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });

  function easeOut(t) { return 1 - Math.pow(1 - t, 3); }

  function run() {
    var dur = 1100, start = null;
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
