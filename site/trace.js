// The run, event by event: one lane per agent plus the notice board, the bank
// and the courthouse; messages and transfers as arrows; colour = protocol layer.
// x is the replay's own clock (Replay.schedule in roblox/src/shared/NandaTown/
// Replay.luau, ported below), so the chart lines up with the movie: hover an
// event for what happened, click it to jump the movie there.
(function () {
  "use strict";

  // Movie time of replay clock 0: title card, then the replay (Movie.luau timeline
  // minus the cut's lead-in; see roblox/tools/cut_movie.py).
  const VIDEO_OFFSET = 5.2;

  // Util.LAYER_COLORS from the replay, a little quieter for paper.
  const LAYER = {
    transport: { color: "#5b9be6", building: "Roads and couriers", note: "envelopes and crates on the road" },
    negotiation: { color: "#e2705a", building: "Market stalls", note: "offers in speech bubbles" },
    payments: { color: "#d8921c", building: "Bank and vault", note: "coins into escrow, out to the seller" },
    trust: { color: "#b8a81e", building: "Review wall", note: "receipts pinned, stars over heads" },
    registry: { color: "#5fae6b", building: "Notice board", note: "agent cards pinned" },
    identity: { color: "#9d82d6", building: "Notice board", note: "one key per agent" },
    memory: { color: "#8c8cc0", building: "The agent's notebook", note: "what the buyer remembers" },
    communication: { color: "#5fb3d9", building: "The agent itself", note: "spots the duplicate copy" },
    data_facts: { color: "#4a4741", building: "Courthouse", note: "evidence and the verdict" },
    auth: { color: "#d9605a", building: "Gate and guards", note: "no forged signatures in this run" },
    town: { color: "#a39e94", building: "(bookkeeping)", note: "run created, agents join" },
  };
  const FAULT = "#d9480f";

  // ---- the replay's schedule (Replay.schedule, target 52 s) ----------------
  const MIN_GAP = {
    account_opened: 0.35, run_created: 0.6, participant_joined: 0.55, identity_created: 0.3,
    card_registered: 0.55, card_unverified: 0.9, message_sent: 0.55, message_delivered: 0.35,
    negotiation_started: 1.4, offer_made: 1.4, counter_made: 1.6, offer_accepted: 1.6,
    escrow_held: 2.0, escrow_released: 2.0, payment_settled: 1.4, receipt_attested: 1.7,
    reputation_updated: 1.9, memory_written: 1.2, duplicate_recognized: 1.8,
    message_duplicated: 1.6, message_dropped: 1.6, run_finished: 1.5,
  };
  function schedule(evs, target) {
    function pass(scale, gfac) {
      const d = [];
      let prevAt = 0, prevD = 0;
      evs.forEach((e, i) => {
        const gap = (MIN_GAP[e.kind] || 1.0) * gfac;
        if (i === 0) d[i] = 0.5;
        else {
          let dl = e.at - prevAt;
          if (dl > 0.3) dl = 0.3 + (dl - 0.3) * 0.25;
          d[i] = prevD + Math.max(gap, dl * scale);
        }
        prevAt = e.at; prevD = d[i];
      });
      return d;
    }
    function search(lo, hi, f) {
      for (let k = 0; k < 30; k++) {
        const mid = (lo + hi) / 2;
        const d = f(mid);
        if (d[d.length - 1] < target) lo = mid; else hi = mid;
      }
      return lo;
    }
    const d = pass(5, 1);
    if (d[d.length - 1] > target) return pass(5, search(0.35, 1, (x) => pass(5, x)));
    return pass(search(5, 200, (x) => pass(x, 1)), 1);
  }

  // ---- words ---------------------------------------------------------------
  const money = (c) => "$" + (c / 100).toFixed(2);
  function describe(e, t) {
    const d = e.detail || {};
    switch (e.kind) {
      case "account_opened": return `The bank opens an account for ${e.subject} with ${money(d.balance_cents)}.`;
      case "run_created": return `Run created: scenario ${d.scenario}, seed ${d.seed}.`;
      case "participant_joined": return `${e.subject} joins as a ${d.role}.`;
      case "identity_created": return `${e.subject} gets identity ${d.agent_id}.`;
      case "card_registered": return `${e.subject} pins a verified card to the notice board: ${(d.capabilities || []).join(", ")}.`;
      case "message_sent": return `${e.observer} sends ${d.kind} to ${d.to}.`;
      case "message_delivered": {
        const m = t.messages[e.subject];
        const second = m && m.deliveries.length > 1 && m.deliveries[1] === e.seq;
        return `${d.kind} from ${e.from} arrives at ${d.to}${second ? " (the second copy)" : ""}.`;
      }
      case "message_duplicated": return `Injected fault: the network duplicates ${e.from}'s ${d.kind} to ${d.to}.`;
      case "negotiation_started": return `${e.observer} opens a negotiation with ${d.seller} over a ${d.subject}.`;
      case "offer_made": return `${e.observer} offers ${money(d.cents)} a unit.`;
      case "counter_made": return `${e.observer} counters at ${money(d.cents)}.`;
      case "offer_accepted": return `${e.observer} accepts ${money(d.cents)}.`;
      case "escrow_held": return `The bank holds ${money(d.cents)} from ${d.from} in escrow.`;
      case "escrow_released": return `Escrow releases ${money(d.cents)} to ${d.to}.`;
      case "payment_settled": return `Payment settled: ${d.from} → ${d.to}, ${money(d.cents)}${d.via ? " via " + d.via : ""}.`;
      case "receipt_attested": return `${e.observer} files a receipt on ${e.subject}: ${d.claim} = ${d.value}.`;
      case "reputation_updated": return `${e.subject}'s reputation ${d.delta >= 0 ? "+" : ""}${d.delta} → ${d.score}.`;
      case "memory_written": return `${e.subject} remembers ${d.key}.`;
      case "duplicate_recognized": return `${e.observer} recognises the duplicate ${d.kind} and ignores it.`;
      case "run_finished": {
        const r = t.result, n = r.stages.filter((s) => s.status === "passed").length;
        return `Run finished at t = ${d.logical_time}. Verdict: ${r.verdict}, ${n} of ${r.stages.length} checks.`;
      }
    }
    return `${e.observer} · ${e.kind} · ${e.subject}`;
  }

  // ---- marks ---------------------------------------------------------------
  // Each event becomes an arrow (from lane → to lane, t0 → t1) or a dot on a lane.
  function marks(t, times) {
    const bySeq = new Map(t.events.map((e, i) => [e.seq, i]));
    const at = (seq) => times[bySeq.get(seq)];
    const out = [];
    t.events.forEach((e, i) => {
      const d = e.detail || {}, x = times[i];
      const base = { e, x, layer: e.layer };
      switch (e.kind) {
        case "message_sent":
          return; // drawn at delivery, from the send time
        case "message_delivered": {
          const m = t.messages[e.subject];
          const second = m.deliveries.length > 1 && m.deliveries[1] === e.seq;
          out.push({ ...base, type: "arrow", from: m.from, to: d.to, x0: at(m.sent_seq), fault: second });
          return;
        }
        case "card_registered":
          out.push({ ...base, type: "arrow", from: e.subject, to: "notice board", x0: x - 0.25 });
          return;
        case "escrow_held":
          out.push({ ...base, type: "arrow", from: d.from, to: "bank", x0: x - 0.6 });
          return;
        case "escrow_released":
          out.push({ ...base, type: "arrow", from: "bank", to: d.to, x0: x - 0.6 });
          return;
        case "receipt_attested":
          out.push({ ...base, type: "arrow", from: e.observer, to: e.subject, x0: x - 0.5 });
          return;
        case "message_duplicated":
          out.push({ ...base, type: "dot", lane: e.from, shape: "fork", fault: true });
          return;
        case "duplicate_recognized":
          out.push({ ...base, type: "dot", lane: e.observer, shape: "cross", fault: true });
          return;
        case "reputation_updated":
          out.push({ ...base, type: "dot", lane: e.subject, shape: "star", label: "rep " + d.score });
          return;
        case "account_opened":
        case "payment_settled":
          out.push({ ...base, type: "dot", lane: "bank" });
          return;
        case "run_created":
          out.push({ ...base, type: "dot", lane: "courthouse", small: true });
          return;
        case "run_finished":
          out.push({ ...base, type: "dot", lane: "courthouse", shape: "verdict" });
          return;
        case "memory_written":
          out.push({ ...base, type: "dot", lane: e.subject, shape: "square" });
          return;
        default: {
          const lane = e.observer === "town" ? e.subject : e.observer;
          out.push({ ...base, type: "dot", lane, small: e.layer === "town" || e.layer === "identity" });
        }
      }
    });
    return out;
  }

  // ---- draw ----------------------------------------------------------------
  const current = { sync: () => {} };
  const movie = document.querySelector("video#movie");
  if (movie) {
    ["timeupdate", "seeked", "play", "pause"].forEach((k) => movie.addEventListener(k, () => current.sync()));
    (function loop() {
      if (!movie.paused) current.sync();
      requestAnimationFrame(loop);
    })();
  }

  function draw(t) {
    const root = d3.select("#trace-chart");
    root.selectAll("*").remove();
    const width = root.node().clientWidth;
    const sellers = t.participants.filter((p) => p.role === "seller").map((p) => p.name);
    const buyers = t.participants.filter((p) => p.role === "buyer").map((p) => p.name);
    const lanes = ["notice board", sellers[0], ...buyers, ...sellers.slice(1), "bank", "courthouse"];
    const times = schedule(t.events, 52);
    const ms = marks(t, times);

    const m = { top: 30, right: 16, bottom: 34, left: 98 };
    const laneH = 40;
    const height = m.top + m.bottom + laneH * (lanes.length - 1);
    const x = d3.scaleLinear().domain([0, times[times.length - 1] + 0.8]).range([m.left, width - m.right]);
    const y = d3.scalePoint().domain(lanes).range([m.top, height - m.bottom]);

    const svg = root.append("svg").attr("viewBox", `0 0 ${width} ${height}`).attr("width", width).attr("height", height)
      .attr("role", "img").attr("aria-label", "Timeline of the 65 events of the marketplace run, one lane per agent");

    // chapter bands (the movie's captions)
    const chapters = [
      [14, "quotes"], [22, "haggle"], [30, "escrow"], [34, "duplicate"], [43, "round 2"], [65, "verdict"],
    ];
    const idx = new Map(t.events.map((e, i) => [e.seq, i]));
    const bandG = svg.append("g").attr("class", "bands");
    chapters.forEach(([seq, name], k) => {
      const x0 = x(times[idx.get(seq)]) - 4;
      bandG.append("line").attr("x1", x0).attr("x2", x0).attr("y1", m.top - 18).attr("y2", height - m.bottom + 6);
      bandG.append("text").attr("x", x0 + 3).attr("y", m.top - 20).text(name);
    });

    // lanes
    const laneG = svg.append("g").attr("class", "lanes");
    lanes.forEach((l) => {
      laneG.append("line").attr("x1", m.left - 6).attr("x2", width - m.right).attr("y1", y(l)).attr("y2", y(l));
      laneG.append("text").attr("x", m.left - 12).attr("y", y(l)).attr("dy", "0.32em").attr("text-anchor", "end").text(l);
    });

    // logical time axis: label each new logical time once there's room
    const axis = svg.append("g").attr("class", "axis");
    let lastPx = -1e9, lastAt = -1;
    t.events.forEach((e, i) => {
      const px = x(times[i]);
      if (e.at !== lastAt && px - lastPx > 44) {
        axis.append("line").attr("x1", px).attr("x2", px).attr("y1", height - m.bottom + 8).attr("y2", height - m.bottom + 12);
        axis.append("text").attr("x", px).attr("y", height - m.bottom + 24).attr("text-anchor", "middle")
          .text((lastAt < 0 ? "t = " : "") + (+e.at.toFixed(2)));
        lastPx = px;
      }
      lastAt = e.at;
    });
    axis.append("text").attr("class", "unit").attr("x", width - m.right).attr("y", height - m.bottom + 24)
      .attr("text-anchor", "end").text("logical seconds");

    // arrowheads per colour
    const defs = svg.append("defs");
    const colorOf = (mk) => (mk.fault ? FAULT : (LAYER[mk.layer] || LAYER.town).color);
    const heads = new Set(ms.filter((d) => d.type === "arrow").map(colorOf));
    heads.forEach((c) => {
      defs.append("marker").attr("id", "h" + c.slice(1)).attr("viewBox", "0 0 8 8").attr("refX", 7).attr("refY", 4)
        .attr("markerWidth", 6).attr("markerHeight", 6).attr("orient", "auto")
        .append("path").attr("d", "M0,0L8,4L0,8z").attr("fill", c);
    });

    const g = svg.append("g").attr("class", "marks");
    const arrows = g.selectAll("path.arrow").data(ms.filter((d) => d.type === "arrow")).join("path")
      .attr("class", (d) => "arrow mark" + (d.fault ? " fault" : ""))
      .attr("d", (d) => {
        const x0 = x(d.x0), x1 = x(d.x), y0 = y(d.from), y1 = y(d.to);
        const dy = y1 > y0 ? -5 : 5;
        return `M${x0},${y0}L${x1},${y1 + dy}`;
      })
      .attr("stroke", colorOf).attr("marker-end", (d) => `url(#h${colorOf(d).slice(1)})`);

    const dots = g.selectAll("g.dot").data(ms.filter((d) => d.type === "dot")).join("g")
      .attr("class", "dot mark").attr("transform", (d) => `translate(${x(d.x)},${y(d.lane)})`);
    dots.each(function (d) {
      const s = d3.select(this), c = colorOf(d);
      if (d.shape === "star") {
        s.append("path").attr("d", d3.symbol(d3.symbolStar, 90)()).attr("fill", c);
        s.append("text").attr("class", "lbl").attr("y", -10).attr("text-anchor", "middle").text(d.label);
      } else if (d.shape === "cross") {
        s.append("path").attr("d", d3.symbol(d3.symbolX, 70)()).attr("fill", c);
        s.append("text").attr("class", "lbl fault").attr("y", -10).attr("text-anchor", "middle").text("copy ignored");
      } else if (d.shape === "fork") {
        s.append("path").attr("d", d3.symbol(d3.symbolDiamond, 60)()).attr("fill", c);
        s.append("text").attr("class", "lbl fault").attr("y", 19).attr("text-anchor", "middle").text("sent twice");
      } else if (d.shape === "square") {
        s.append("rect").attr("x", -3.5).attr("y", -3.5).attr("width", 7).attr("height", 7).attr("fill", c);
      } else if (d.shape === "verdict") {
        s.append("circle").attr("r", 7).attr("fill", "var(--accent)").attr("stroke", c).attr("stroke-width", 1.5);
        const r = t.result, n = r.stages.filter((st) => st.status === "passed").length;
        s.append("text").attr("class", "lbl verdict").attr("x", -11).attr("dy", "0.32em").attr("text-anchor", "end")
          .text(`${r.verdict} · ${n}/${r.stages.length}`);
      } else {
        s.append("circle").attr("r", d.small ? 2.5 : 4).attr("fill", c);
      }
      s.append("circle").attr("class", "hit").attr("r", 9);
    });
    arrows.clone(true).attr("class", "hit-line").attr("marker-end", null);

    // tooltip + click to seek
    const tip = d3.select("#trace-tip");
    const video = document.querySelector("video#movie");
    function show(ev, d) {
      const e = d.e;
      tip.style("display", "block").html(
        `<span class="k">ev-${e.seq} · ${e.layer.replace("_", " ")} · t = ${+e.at.toFixed(2)}</span>` +
        `<span class="d">${describe(e, t)}</span>` + (video ? `<span class="k">click to see it in the movie</span>` : ""));
      const box = root.node().getBoundingClientRect();
      const tx = Math.min(ev.clientX - box.left + 14, box.width - 260);
      tip.style("left", tx + "px").style("top", ev.clientY - box.top + 16 + "px");
    }
    g.selectAll(".dot, .hit-line, .arrow")
      .on("mousemove", show).on("mouseleave", () => tip.style("display", "none"))
      .on("click", (ev, d) => {
        if (!video) return;
        video.currentTime = Math.max(0, d.x + VIDEO_OFFSET - 1.0);
        video.play();
      });

    // playhead follows the movie; events still to come are dimmed while it plays
    const head = svg.append("line").attr("class", "playhead").attr("y1", m.top - 10).attr("y2", height - m.bottom + 6)
      .style("display", "none");
    function sync() {
      if (!video) return;
      const ct = video.currentTime - VIDEO_OFFSET;
      const on = video.currentTime > 0.05 && ct > -VIDEO_OFFSET;
      head.style("display", on && ct >= 0 ? null : "none").attr("x1", x(Math.max(ct, 0))).attr("x2", x(Math.max(ct, 0)));
      g.selectAll(".mark").classed("later", (d) => on && d.x > ct);
    }
    current.sync = sync;
    sync();

    // layer table, folded into the legend
    const counts = d3.rollup(t.events, (v) => v, (e) => e.layer);
    const rows = Object.keys(LAYER).filter((l) => l !== "town").map((l) => {
      const ev = counts.get(l) || [];
      const kinds = d3.rollups(ev, (v) => v.length, (e) => e.kind).map(([k, n]) => (n > 1 ? `${k} ×${n}` : k));
      return { l, n: ev.length, kinds };
    });
    const tb = d3.select("#layer-table tbody");
    tb.selectAll("tr").data(rows).join("tr").html((r) =>
      `<td><span class="sw" style="background:${LAYER[r.l].color}"></span>${r.l.replace("_", "&#8203;_")}</td>` +
      `<td>${LAYER[r.l].building}</td>` +
      `<td class="n">${r.n || "–"}</td>` +
      `<td class="kinds">${r.n ? r.kinds.join(", ") : LAYER[r.l].note}</td>`);
  }

  fetch("data/marketplace.json").then((r) => r.json()).then((t) => {
    draw(t);
    let w = document.querySelector("#trace-chart").clientWidth;
    window.addEventListener("resize", () => {
      const nw = document.querySelector("#trace-chart").clientWidth;
      if (nw !== w) { w = nw; draw(t); }
    });
  });
})();
