(function () {
  "use strict";
  var root = document.documentElement;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };
  var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  var lang = function () { return root.lang && root.lang.indexOf("de") === 0 ? "de" : "en"; };
  var listeners = [];

  /* Language */
  function setLang(l, user) {
    root.lang = l;
    $$(".lang button").forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.set === l)); });
    if (user) { try { localStorage.setItem("sc.lang", l); } catch (e) {} }
    listeners.forEach(function (f) { f(l); });
  }
  var saved = null;
  try { saved = localStorage.getItem("sc.lang"); } catch (e) {}
  setLang(saved || root.getAttribute("data-default-lang") || ((navigator.language || "en").toLowerCase().indexOf("de") === 0 ? "de" : "en"));
  $$(".lang button").forEach(function (b) { b.addEventListener("click", function () { setLang(b.dataset.set, true); }); });

  /* Header */
  var top = $(".top");
  if (top) {
    var onScroll = function () {
      top.classList.toggle("scrolled", window.scrollY > 8);
      var w = $(".win"); if (w) w.classList.toggle("flat", window.scrollY > 120);
    };
    window.addEventListener("scroll", onScroll, { passive: true }); onScroll();
    var mb = $(".menu-btn");
    if (mb) {
      mb.addEventListener("click", function () { var o = top.classList.toggle("open"); mb.setAttribute("aria-expanded", String(o)); });
      $$(".nav a").forEach(function (a) { a.addEventListener("click", function () { top.classList.remove("open"); mb.setAttribute("aria-expanded", "false"); }); });
    }
  }

  /* Pointer light */
  var hero = $(".hero");
  if (hero && !reduce) hero.addEventListener("pointermove", function (e) {
    var r = hero.getBoundingClientRect();
    hero.style.setProperty("--mx", (e.clientX - r.left) + "px"); hero.style.setProperty("--my", (e.clientY - r.top) + "px");
  });
  $$(".card").forEach(function (c) {
    c.addEventListener("pointermove", function (e) {
      var r = c.getBoundingClientRect();
      c.style.setProperty("--cx", (e.clientX - r.left) + "px"); c.style.setProperty("--cy", (e.clientY - r.top) + "px");
    });
  });

  /* Visible-only runner: loops pause when off screen */
  function whenVisible(el, cb) {
    if (!el) return;
    if (!("IntersectionObserver" in window)) { cb(true); return; }
    new IntersectionObserver(function (es) { es.forEach(function (x) { cb(x.isIntersecting); }); }, { threshold: .15 }).observe(el);
  }

  /* App window demo */
  var demo = $("#demo");
  if (demo && !reduce) {
    var D = demo.dataset;
    var prompts = {
      en: D.promptEn || "Add a dark mode switch to the settings page and remember the choice.",
      de: D.promptDe || "Bau auf der Einstellungsseite einen Dark-Mode-Schalter ein und merk dir die Wahl."
    };
    var lab = function (k, en, de) { return lang() === "de" ? (D[k + "De"] || de) : (D[k + "En"] || en); };
    var linesAt = +(D.linesPhase || 1), countAt = +(D.countPhase || 3), countMax = +(D.countMax || 4);
    var run = 0, visible = true;
    whenVisible(demo, function (v) { visible = v; });
    var wait = async function (ms, id) { var end = Date.now() + ms; while (Date.now() < end || !visible) { if (id !== run) throw 0; await sleep(80); } };
    var play = async function () {
      var id = ++run;
      try {
        await wait(900, id);
        while (true) {
          var txt = $(".txt", demo), chips = $$(".chip", demo), ph = $$(".ph", demo), lines = $$(".diff .ln, .draft .ln", demo);
          var chk = $(".chk", demo), pr = $(".fake.pri", demo), toast = $(".toast", demo), lbl = $(".chk .lbl", demo);
          txt.textContent = ""; chips.forEach(function (c) { c.classList.add("pend"); });
          ph.forEach(function (p) { p.classList.remove("done", "now"); $(".tl", p).textContent = ""; });
          lines.forEach(function (l) { if (!l.classList.contains("ctx")) l.classList.add("pend"); });
          chk.classList.remove("green"); lbl.textContent = lab("wait", "waiting", "wartet"); $(".cnt", demo).textContent = "0 / " + countMax;
          pr.classList.remove("glow"); toast.classList.remove("show");
          await wait(500, id);
          var t = prompts[lang()];
          for (var i = 0; i <= t.length; i++) { txt.textContent = t.slice(0, i); await wait(22 + Math.random() * 30, id); }
          await wait(350, id);
          for (var c = 0; c < chips.length; c++) { chips[c].classList.remove("pend"); await wait(170, id); }
          var times = (D.times || "4s,38s,6s,21s").split(",");
          for (var k = 0; k < ph.length; k++) {
            ph[k].classList.add("now");
            if (k === linesAt) { for (var j = 0; j < lines.length; j++) { lines[j].classList.remove("pend"); await wait(190, id); } }
            else if (k === countAt) { for (var n = 1; n <= countMax; n++) { $(".cnt", demo).textContent = n + " / " + countMax; await wait(380, id); } }
            else await wait(800, id);
            ph[k].classList.remove("now"); ph[k].classList.add("done"); $(".tl", ph[k]).textContent = times[k];
          }
          chk.classList.add("green"); lbl.textContent = lab("done", "checks green", "Prüfungen grün");
          await wait(500, id); pr.classList.add("glow");
          await wait(1400, id); toast.classList.add("show");
          await wait(4200, id);
        }
      } catch (e) {}
    };
    listeners.push(function () { play(); });
    play();
  }

  /* Routing card */
  var route = $("#route");
  if (route && !reduce) {
    var tasks = {
      en: [["Build a checkout page", "build → Claude Code"], ["Why does the login test fail?", "debug → Junie"], ["Review the auth refactor", "review → Codex"], ["Fix typo in README", "small → local"]],
      de: [["Checkout-Seite bauen", "bauen → Claude Code"], ["Warum schlägt der Login-Test fehl?", "debuggen → Junie"], ["Auth-Refactor prüfen", "Review → Codex"], ["Tippfehler im README", "klein → lokal"]]
    };
    var ri = 0, rv = true; whenVisible(route, function (v) { rv = v; });
    setInterval(function () {
      if (!rv) return;
      ri = (ri + 1) % 4;
      var t = tasks[lang()][ri];
      $(".in b", route).textContent = t[0]; $(".in small", route).textContent = t[1];
      $$(".out span", route).forEach(function (s, i) { s.classList.toggle("sel", i === ri); });
    }, 2200);
  }

  /* PR title typing */
  var ttl = $("#pr-title");
  if (ttl && !reduce) {
    var titles = ["feat(settings): dark mode switch with saved preference", "fix(auth): keep session after password reset", "refactor(cart): rename helpers, no behavior change"];
    var ti = 0, tv = true; whenVisible(ttl, function (v) { tv = v; });
    (async function () {
      while (true) {
        await sleep(2600); if (!tv) continue;
        ti = (ti + 1) % titles.length; var s = titles[ti];
        ttl.classList.add("typed");
        for (var i = ttl.textContent.length; i >= 0; i--) { ttl.textContent = ttl.textContent.slice(0, i); await sleep(12); }
        for (var j = 0; j <= s.length; j++) { ttl.textContent = s.slice(0, j); await sleep(28); }
        ttl.classList.remove("typed");
      }
    })();
  }

  /* Local terminal */
  var term = $("#term");
  if (term && !reduce) {
    var tl = $$(".ln", term), tvv = true; whenVisible(term, function (v) { tvv = v; });
    (async function () {
      while (true) {
        await sleep(1200); if (!tvv) continue;
        tl.forEach(function (l) { l.style.opacity = ".12"; });
        for (var i = 0; i < tl.length; i++) { await sleep(i % 5 === 4 ? 650 : 420); tl[i].style.opacity = "1"; }
        await sleep(4200);
      }
    })();
  }

  /* Workspace tabs */
  var tabs = $$(".tabs button"), panes = $$(".tp");
  if (tabs.length) {
    var cur = 0, auto = !reduce, tabVisible = true, timer = null;
    var show = function (i, fromUser) {
      cur = i;
      tabs.forEach(function (b, k) {
        b.setAttribute("aria-selected", String(k === i)); b.tabIndex = k === i ? 0 : -1;
        var p = $(".prog", b); p.classList.remove("run"); void p.offsetWidth;
        if (k === i && auto) p.classList.add("run");
      });
      panes.forEach(function (p, k) { p.classList.toggle("on", k === i); });
      if (fromUser) { auto = false; clearInterval(timer); }
    };
    tabs.forEach(function (b, i) {
      b.addEventListener("click", function () { show(i, true); });
      b.addEventListener("keydown", function (e) {
        if (e.key === "ArrowRight" || e.key === "ArrowLeft") { var n = (i + (e.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length; show(n, true); tabs[n].focus(); }
      });
    });
    whenVisible($(".tabs"), function (v) { tabVisible = v; });
    if (auto) timer = setInterval(function () { if (tabVisible && auto) show((cur + 1) % tabs.length); }, 6000);
    show(0);
  }

  /* Counters */
  var nums = $$("[data-to]");
  if (nums.length && !reduce && "IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (x) {
        if (!x.isIntersecting) return; io.unobserve(x.target);
        var el = x.target, to = parseFloat(el.dataset.to), suf = el.dataset.suf || "", t0 = performance.now();
        var step = function (t) { var p = Math.min(1, (t - t0) / 1300); el.textContent = Math.round(to * (1 - Math.pow(1 - p, 3))) + suf; if (p < 1) requestAnimationFrame(step); };
        requestAnimationFrame(step);
      });
    }, { threshold: .6 });
    nums.forEach(function (n) { io.observe(n); });
  }

  /* Countdown */
  var cd = $("[data-countdown]");
  if (cd) {
    var target = new Date(cd.dataset.countdown).getTime();
    var tick = function () {
      var d = Math.max(0, target - Date.now()), u = [864e5, 36e5, 6e4, 1e3], v = [];
      u.forEach(function (x) { v.push(Math.floor(d / x)); d %= x; });
      $$("b", cd).forEach(function (b, i) { b.textContent = String(v[i]).padStart(2, "0"); });
    };
    tick(); setInterval(tick, 1000);
  }
  $$("form[data-preview]").forEach(function (f) {
    f.addEventListener("submit", function (e) { e.preventDefault(); var m = $(".form-msg", f); if (m) m.hidden = false; });
  });

  /* Newest version from GitHub (silently skipped if unreachable) */
  if ($(".ver")) try {
    fetch("https://api.github.com/repos/salenta-code/salenta-code/releases/latest").then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (j && j.tag_name) $$(".ver").forEach(function (e) { e.textContent = String(j.tag_name).replace(/^v/, ""); });
    }).catch(function () {});
  } catch (e) {}
})();
