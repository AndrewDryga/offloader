/* Mixpanel — lightweight web analytics for the marketing site.
 *
 * Deliberately narrow: automatic page views + outbound intent clicks (Book a
 * call, GitHub) only. Autocapture is OFF and nothing reads form fields, so the ROI
 * calculator's numbers are never touched — its "your numbers never leave this page"
 * promise stays literally true. Honors Do Not Track (Mixpanel's default). US
 * residency; for the EU add  api_host: 'https://api-eu.mixpanel.com'  below.
 */
(function () {
if (location.hostname !== "offloader.dryga.com") return;
var dnt = navigator.doNotTrack || window.doNotTrack || navigator.msDoNotTrack;
if (dnt === "1" || dnt === "yes") return;

(function (f, b) {
  if (!b.__SV) {
    var e, g, i, h;
    window.mixpanel = b;
    b._i = [];
    b.init = function (e, f, c) {
      function g(a, d) { var b = d.split("."); 2 == b.length && ((a = a[b[0]]), (d = b[1])); a[d] = function () { a.push([d].concat(Array.prototype.slice.call(arguments, 0))); }; }
      var a = b;
      "undefined" !== typeof c ? (a = b[c] = []) : (c = "mixpanel");
      a.people = a.people || [];
      a.toString = function (a) { var d = "mixpanel"; "mixpanel" !== c && (d += "." + c); a || (d += " (stub)"); return d; };
      a.people.toString = function () { return a.toString(1) + ".people (stub)"; };
      i = "disable time_event track track_pageview track_links track_forms track_with_groups add_group set_group remove_group register register_once alias unregister identify name_tag set_config reset opt_in_tracking opt_out_tracking has_opted_in_tracking has_opted_out_tracking clear_opt_in_out_tracking start_batch_senders people.set people.set_once people.unset people.increment people.append people.union people.track_charge people.clear_charges people.delete_user people.remove".split(" ");
      for (h = 0; h < i.length; h++) g(a, i[h]);
      var j = "set set_once union unset remove delete".split(" ");
      a.get_group = function () { function b(c) { d[c] = function () { call2_args = arguments; call2 = [c].concat(Array.prototype.slice.call(call2_args, 0)); a.push([e, call2]); }; } for (var d = {}, e = ["get_group"].concat(Array.prototype.slice.call(arguments, 0)), c = 0; c < j.length; c++) b(j[c]); return d; };
      b._i.push([e, f, c]);
    };
    b.__SV = 1.2;
    e = f.createElement("script"); e.type = "text/javascript"; e.async = !0;
    e.src = "//cdn.mxpnl.com/libs/mixpanel-2-latest.min.js";
    g = f.getElementsByTagName("script")[0]; g.parentNode.insertBefore(e, g);
  }
})(document, window.mixpanel || []);

(function () {
  var mp = window.mixpanel;
  if (!mp || !mp.init) return;

  mp.init("6bbeae2a8fcbc0325772762c3997d67e", {
    debug: false,
    track_pageview: true, // auto page views only
    // Set explicitly because the -latest SDK can change its defaults, and the ROI page
    // promises that its inputs never leave the page.
    autocapture: false,
    record_sessions_percent: 0,
    persistence: "localStorage"
    // EU data residency: add  api_host: "https://api-eu.mixpanel.com"
  });

  // Clicks measure intent, not completed bookings or installs. No PII or form inputs.
  document.addEventListener(
    "click",
    function (e) {
      var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
      if (!a) return;
      var destination;
      try { destination = new URL(a.getAttribute("href"), location.href); } catch (_) { return; }
      if (destination.protocol !== "https:") return;
      if (destination.hostname === "cal.com" && destination.pathname === "/andrew-dryga/offloader") {
        mp.track("book_call_click", { location: location.pathname, label: (a.textContent || "").trim().slice(0, 60) });
      } else if (destination.hostname === "github.com") {
        mp.track("github_click", { location: location.pathname });
      }
    },
    true
  );
})();
})();
