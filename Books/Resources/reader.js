(() => {
  if (window.Reader) return;
  const LOAD_ID = (window.__readerConfig || {}).loadID || 0;
  const post = (msg) => { msg.lid = LOAD_ID; window.webkit.messageHandlers.reader.postMessage(msg); };
  let lastOffset = null;
  const se = () => document.scrollingElement || document.documentElement;

  let cfg = window.__readerConfig || { layout: 'paginated', spread: 'auto', marginMin: 56, vmargin: 52, size: 19 };
  let metrics = { cols: 1, m: 56 };
  let page = 0;

  function computeMetrics(c) {
    const w = window.innerWidth;
    let cols = c.spread === 'double' ? 2 : c.spread === 'single' ? 1 : (w >= 1180 ? 2 : 1);
    if (c.layout !== 'paginated') cols = 1;
    // Cover and full-page illustration documents read better centered on one page.
    const b = document.body;
    if (b && (b.textContent || '').trim().length < 120 && b.querySelector('img, svg, image')) cols = 1;
    const maxLine = (c.size || 19) * 34;
    let m = c.marginMin || 40;
    if (c.layout === 'paginated') m = Math.max(m, cols === 1 ? (w - maxLine) / 2 : (w - 2 * maxLine) / 4);
    return { cols, m: Math.round(m) };
  }
  let ready = false;
  let pendingTarget = null;

  // ---------- Styling ----------

  function css(c) {
    metrics = computeMetrics(c);
    const M = metrics.m;
    if (c.layout === 'fixed') {
      return `html, body { margin: 0 !important; padding: 0 !important; overflow: hidden !important; background: ${c.bg}; }
        body { transform-origin: 0 0; }
        ::selection { background: rgba(176, 101, 43, 0.28); }`;
    }
    const font = c.font ? `body, body *:not(code):not(pre):not(kbd):not(samp):not(tt) { font-family: ${c.font} !important; }` : '';
    const align = c.justify ? `body p, body li, body dd { text-align: justify; }` : '';
    const hyph = c.hyphenate ? `body p, body li, body dd { -webkit-hyphens: auto; hyphens: auto; }` : '';
    const base = `
      :root { color-scheme: ${c.dark ? 'dark' : 'light'}; }
      html { background: ${c.bg} !important; color: ${c.fg} !important; -webkit-text-size-adjust: none; text-rendering: optimizeLegibility; -webkit-font-smoothing: antialiased; font-kerning: normal; font-variant-ligatures: common-ligatures; }
      body { background: transparent !important; color: inherit !important; font-size: ${c.size}px !important; line-height: ${c.lineHeight} !important; widows: 2; orphans: 2; overflow-wrap: break-word; }
      body *:not(mark) { color: inherit !important; background-color: transparent !important; }
      body p, body li, body blockquote, body dd, body div { line-height: inherit !important; }
      body a, body a * { color: ${c.accent} !important; text-decoration: none !important; }
      body h1, body h2, body h3 { line-height: 1.25 !important; -webkit-hyphens: manual; hyphens: manual; text-align: center; }
      img, svg, video, canvas { max-width: 100% !important; height: auto; }
      pre { white-space: pre-wrap !important; }
      table { max-width: 100%; }
      hr { border: none; border-top: 1px solid ${c.secondary}; opacity: 0.5; width: 30%; margin: 2em auto; }
      ::selection { background: ${c.dark ? 'rgba(227, 168, 87, 0.35)' : 'rgba(176, 101, 43, 0.25)'}; }
      mark.bk-hl { color: inherit !important; border-radius: 3px; padding: 0.05em 0; cursor: pointer; -webkit-box-decoration-break: clone; transition: background-color 0.2s; }
      mark.bk-hl.yellow { background-color: rgba(247, 209, 84, ${c.dark ? 0.38 : 0.55}) !important; }
      mark.bk-hl.green { background-color: rgba(143, 209, 139, ${c.dark ? 0.35 : 0.55}) !important; }
      mark.bk-hl.blue { background-color: rgba(139, 195, 242, ${c.dark ? 0.35 : 0.55}) !important; }
      mark.bk-hl.pink { background-color: rgba(244, 155, 184, ${c.dark ? 0.35 : 0.55}) !important; }
      mark.bk-hl.purple { background-color: rgba(193, 163, 240, ${c.dark ? 0.35 : 0.55}) !important; }
      mark.bk-hl.underline { background-color: transparent !important; text-decoration: underline 2px rgba(226, 91, 69, 0.9) !important; text-underline-offset: 3px; }
      mark.bk-hl.has-note { border-bottom: 1.5px dotted currentColor; }
      mark.bk-find { background-color: rgba(255, 196, 0, 0.75) !important; color: #000 !important; border-radius: 3px; animation: bkpulse 1.6s ease-out 1; }
      @keyframes bkpulse { 0% { box-shadow: 0 0 0 0 rgba(255, 196, 0, 0.8); } 100% { box-shadow: 0 0 0 10px rgba(255, 196, 0, 0); } }
      ${font} ${align} ${hyph}`;
    if (c.layout === 'paginated') {
      const colW = Math.floor((window.innerWidth - 2 * M - (metrics.cols - 1) * 2 * M) / metrics.cols);
      return base + `
        html { height: 100vh !important; width: 100vw !important; margin: 0 !important; padding: 0 !important; overflow: hidden !important; }
        body { box-sizing: border-box !important; height: calc(100vh - ${c.vmargin * 2}px) !important; margin: ${c.vmargin}px ${M}px !important;
               padding: 0 !important; column-width: ${colW}px !important; column-count: ${metrics.cols} !important; column-gap: ${M * 2}px !important; column-fill: auto !important;
               max-width: none !important; min-height: 0 !important; overflow: visible !important; }
        img, svg, video { max-height: calc(100vh - ${c.vmargin * 2 + 8}px) !important; object-fit: contain; -webkit-column-break-inside: avoid; break-inside: avoid; }
        h1, h2, h3, h4 { break-after: avoid; }`;
    }
    return base + `
      html { overflow-x: hidden !important; padding: 0 !important; margin: 0 !important; }
      body { max-width: ${c.maxWidth}px; margin: 0 auto !important; padding: ${c.vmargin}px ${c.marginMin}px ${c.vmargin * 3}px !important; box-sizing: border-box; }`;
  }

  function applyStyle() {
    let style = document.getElementById('bk-style');
    if (!style) {
      style = document.createElement('style');
      style.id = 'bk-style';
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = css(cfg);
    if (cfg.layout === 'fixed') fitFixedLayout();
  }

  function fitFixedLayout() {
    const meta = document.querySelector('meta[name=viewport]');
    let w = 0, h = 0;
    if (meta) {
      const content = meta.getAttribute('content') || '';
      const mw = /width\s*=\s*(\d+)/.exec(content), mh = /height\s*=\s*(\d+)/.exec(content);
      if (mw) w = +mw[1];
      if (mh) h = +mh[1];
    }
    if (!w || !h) {
      const img = document.querySelector('img, svg');
      const r = img ? img.getBoundingClientRect() : document.body.getBoundingClientRect();
      w = r.width || window.innerWidth;
      h = r.height || window.innerHeight;
    }
    const scale = Math.min(window.innerWidth / w, window.innerHeight / h);
    const dx = (window.innerWidth - w * scale) / 2, dy = (window.innerHeight - h * scale) / 2;
    document.body.style.width = w + 'px';
    document.body.style.height = h + 'px';
    document.body.style.transform = `translate(${dx}px, ${dy}px) scale(${scale})`;
  }

  // ---------- Text offsets ----------

  function textNodes() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function offsetOf(container, offset) {
    const r = document.createRange();
    r.setStart(document.body, 0);
    try { r.setEnd(container, offset); } catch (e) { return 0; }
    return r.toString().length;
  }

  function resolve(offset) {
    let acc = 0;
    const nodes = textNodes();
    for (const n of nodes) {
      const len = n.data.length;
      if (acc + len >= offset) return { node: n, offset: Math.max(0, offset - acc) };
      acc += len;
    }
    const last = nodes[nodes.length - 1];
    return last ? { node: last, offset: last.data.length } : null;
  }

  function rangeFor(start, end) {
    const a = resolve(start), b = resolve(end);
    if (!a || !b) return null;
    const r = document.createRange();
    r.setStart(a.node, a.offset);
    r.setEnd(b.node, b.offset);
    return r;
  }

  // ---------- Pagination ----------

  const W = () => window.innerWidth;
  const H = () => window.innerHeight;

  function pageCount() {
    if (cfg.layout !== 'paginated') return 1;
    return Math.max(1, Math.ceil(se().scrollWidth / W() - 0.02));
  }

  function maxScrollTop() { return Math.max(0, se().scrollHeight - H()); }

  function progression() {
    if (cfg.layout === 'paginated') return page / pageCount();
    if (cfg.layout === 'fixed') return 0;
    const m = maxScrollTop();
    return m <= 0 ? 0 : se().scrollTop / m;
  }

  function firstVisibleOffset() {
    if (cfg.layout === 'fixed') return 0;
    const xs = cfg.layout === 'paginated' ? [metrics.m + 4, metrics.m + 40, W() / 4] : [W() / 2 - 100, W() / 3, W() / 2];
    const ys = cfg.layout === 'paginated' ? [cfg.vmargin + 4, cfg.vmargin + 30, H() / 4, H() / 2] : [cfg.vmargin, 40, H() / 6, H() / 3];
    for (const y of ys) for (const x of xs) {
      const r = document.caretRangeFromPoint(x, y);
      if (r && document.body.contains(r.startContainer)) return offsetOf(r.startContainer, r.startOffset);
    }
    return null;
  }

  function pageForOffset(offset) {
    const p = resolve(offset);
    if (!p) return 0;
    const r = document.createRange();
    r.setStart(p.node, Math.min(p.offset, p.node.data.length));
    r.setEnd(p.node, Math.min(p.offset + 1, p.node.data.length));
    let rect = r.getClientRects()[0] || r.getBoundingClientRect();
    if (!rect || (rect.width === 0 && rect.height === 0)) rect = p.node.parentElement.getBoundingClientRect();
    if (cfg.layout === 'paginated') return Math.max(0, Math.min(pageCount() - 1, Math.floor((rect.left + se().scrollLeft) / W())));
    return rect.top + se().scrollTop;
  }

  function snippet(offset) {
    const text = document.body.textContent || '';
    return text.substr(offset || 0, 160).replace(/\s+/g, ' ').trim();
  }

  function atEnd() {
    if (cfg.layout === 'paginated') return page >= pageCount() - 1;
    if (cfg.layout === 'fixed') return true;
    return se().scrollTop >= maxScrollTop() - 4;
  }

  function report() {
    if (!ready) return;
    const off = firstVisibleOffset();
    if (off != null) lastOffset = off;
    post({ type: 'location', page, pageCount: pageCount(), progression: progression(), textOffset: off, snippet: snippet(off), atEnd: atEnd() });
  }

  function goToPage(n, animated) {
    if (cfg.layout !== 'paginated') return;
    page = Math.max(0, Math.min(pageCount() - 1, n));
    const smooth = animated && cfg.animate;
    se().scrollTo({ left: page * W(), top: 0, behavior: smooth ? 'smooth' : 'instant' });
    // The viewport only reflects the new page once the smooth scroll ends.
    if (smooth) setTimeout(report, 420); else report();
  }

  function goToY(y, animated) {
    se().scrollTo({ top: Math.max(0, y - cfg.vmargin), behavior: animated ? 'smooth' : 'instant' });
    setTimeout(report, animated ? 350 : 0);
  }

  function apply(target) {
    if (!target) return;
    if (target.fragment) {
      const el = document.getElementById(target.fragment) || document.getElementsByName(target.fragment)[0];
      if (el) {
        const rect = el.getBoundingClientRect();
        if (cfg.layout === 'paginated') goToPage(Math.floor((rect.left + se().scrollLeft) / W()), false);
        else goToY(rect.top + se().scrollTop, false);
        return;
      }
    }
    if (target.end) {
      if (cfg.layout === 'paginated') goToPage(pageCount() - 1, false);
      else goToY(se().scrollHeight, false);
      return;
    }
    if (target.textOffset != null && target.textOffset > 0) {
      const p = pageForOffset(target.textOffset);
      if (cfg.layout === 'paginated') goToPage(p, false); else goToY(p, false);
      return;
    }
    const prog = target.progression || 0;
    if (cfg.layout === 'paginated') goToPage(Math.floor(prog * pageCount() + 0.0001), false);
    else goToY(prog * maxScrollTop() + cfg.vmargin, false);
  }

  // ---------- Highlights ----------

  function clearMarks(cls) {
    document.querySelectorAll('mark.' + cls).forEach((m) => {
      const parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  function wrapRange(range, make) {
    const nodes = [];
    const walker = document.createTreeWalker(range.commonAncestorContainer.nodeType === 3 ? range.commonAncestorContainer.parentNode : range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) if (range.intersectsNode(walker.currentNode)) nodes.push(walker.currentNode);
    const marks = [];
    for (let node of nodes) {
      let start = node === range.startContainer ? range.startOffset : 0;
      let end = node === range.endContainer ? range.endOffset : node.data.length;
      if (end <= start || !node.data.slice(start, end).trim().length && nodes.length > 1) continue;
      if (start > 0) { node = node.splitText(start); end -= start; }
      if (end < node.data.length) node.splitText(end);
      const mark = make();
      node.parentNode.insertBefore(mark, node);
      mark.appendChild(node);
      marks.push(mark);
    }
    return marks;
  }

  function setHighlights(list) {
    clearMarks('bk-hl');
    for (const h of list) {
      const r = rangeFor(h.start, h.end);
      if (!r) continue;
      wrapRange(r, () => {
        const m = document.createElement('mark');
        m.className = 'bk-hl ' + h.color + (h.note ? ' has-note' : '');
        m.dataset.hl = h.id;
        return m;
      });
    }
  }

  // ---------- Search ----------

  function find(query, occurrence) {
    clearMarks('bk-find');
    const text = (document.body.textContent || '').toLowerCase();
    const q = query.toLowerCase();
    let idx = -1, from = 0;
    for (let i = 0; i <= occurrence; i++) {
      idx = text.indexOf(q, from);
      if (idx < 0) break;
      from = idx + q.length;
    }
    if (idx < 0) return false;
    const r = rangeFor(idx, idx + q.length);
    if (!r) return false;
    const marks = wrapRange(r, () => { const m = document.createElement('mark'); m.className = 'bk-find'; return m; });
    if (marks[0]) {
      const rect = marks[0].getBoundingClientRect();
      if (cfg.layout === 'paginated') goToPage(Math.floor((rect.left + se().scrollLeft) / W()), false);
      else goToY(rect.top + se().scrollTop - H() / 3, false);
    }
    setTimeout(() => clearMarks('bk-find'), 4000);
    return true;
  }

  // ---------- Events ----------

  function rectJSON(r) { return { x: r.left, y: r.top, width: r.width, height: r.height }; }

  let selTimer = null;
  function reportSelection() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) { post({ type: 'selectionCleared' }); return; }
    const range = sel.getRangeAt(0);
    const text = sel.toString();
    if (!text.trim()) return;
    const rects = range.getClientRects();
    const first = rects[0] || range.getBoundingClientRect();
    post({ type: 'selection', text, start: offsetOf(range.startContainer, range.startOffset),
           end: offsetOf(range.endContainer, range.endOffset), rect: rectJSON(first), bounds: rectJSON(range.getBoundingClientRect()) });
  }

  document.addEventListener('selectionchange', () => {
    clearTimeout(selTimer);
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) { post({ type: 'selectionCleared' }); return; }
    selTimer = setTimeout(reportSelection, 350);
  });
  document.addEventListener('mouseup', () => { clearTimeout(selTimer); setTimeout(reportSelection, 10); });

  function isFootnote(a, target) {
    const type = (a.getAttribute('epub:type') || a.getAttributeNS('http://www.idpf.org/2007/ops', 'type') || '') + ' ' + (a.getAttribute('role') || '');
    if (/noteref/.test(type)) return true;
    if (target) {
      const ttype = (target.getAttribute('epub:type') || '') + ' ' + (target.getAttribute('role') || '') + ' ' + (target.className || '');
      if (/footnote|endnote|rearnote|doc-note/.test(ttype) || target.closest('aside')) return true;
    }
    return /^\[?\(?(\d{1,3}|[*†‡§a-z])\)?\]?$/i.test((a.textContent || '').trim()) && !!a.closest('sup, .fnanchor, .footnote, [class*=note]') ||
           /^\[\d{1,3}\]$/.test((a.textContent || '').trim());
  }

  function noteContent(target) {
    let el = target;
    if (!(el.textContent || '').trim() || el.tagName === 'A') el = target.closest('p, li, div, aside, section, dd') || target.parentElement;
    return (el.innerText || el.textContent || '').trim();
  }

  document.addEventListener('click', (e) => {
    const mark = e.target.closest && e.target.closest('mark.bk-hl');
    const a = e.target.closest && e.target.closest('a[href]');
    if (a) {
      e.preventDefault();
      const url = new URL(a.getAttribute('href'), location.href);
      if (url.protocol !== 'file:') { post({ type: 'external', url: url.href }); return; }
      const samePage = url.pathname === location.pathname;
      const frag = decodeURIComponent(url.hash.slice(1));
      const target = samePage && frag ? (document.getElementById(frag) || document.getElementsByName(frag)[0]) : null;
      if (target && isFootnote(a, target)) {
        post({ type: 'footnote', text: noteContent(target), fragment: frag, rect: rectJSON(a.getBoundingClientRect()) });
        return;
      }
      post({ type: 'link', url: url.href, noteRef: !samePage && isFootnote(a, null), rect: rectJSON(a.getBoundingClientRect()) });
      return;
    }
    if (mark && window.getSelection().isCollapsed) {
      post({ type: 'highlightTapped', id: mark.dataset.hl, rect: rectJSON(mark.getBoundingClientRect()) });
      return;
    }
    if (window.getSelection().isCollapsed && e.detail === 1) post({ type: 'tap', x: e.clientX / W(), y: e.clientY / H() });
  }, true);

  let resizeTimer = null;
  let resizeAnchor = null;
  window.addEventListener('resize', () => {
    if (resizeTimer === null) resizeAnchor = lastOffset;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      resizeTimer = null;
      if (cfg.layout === 'fixed') { fitFixedLayout(); return; }
      applyStyle();
      apply(resizeAnchor != null ? { textOffset: resizeAnchor } : { progression: progression() });
      report();
    }, 120);
  });

  let scrollTimer = null;
  window.addEventListener('scroll', () => {
    if (cfg.layout !== 'scroll') return;
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(report, 200);
  }, { passive: true });

  function start() {
    applyStyle();
    const finish = () => {
      ready = true;
      apply(pendingTarget || { progression: 0 });
      pendingTarget = null;
      post({ type: 'ready', pageCount: pageCount() });
      report();
    };
    const fonts = document.fonts ? document.fonts.ready : Promise.resolve();
    Promise.race([fonts, new Promise((r) => setTimeout(r, 400))]).then(() => setTimeout(finish, 0));
    window.addEventListener('load', () => {
      if (cfg.layout === 'fixed') fitFixedLayout();
      else if (ready && lastOffset != null) { apply({ textOffset: lastOffset }); report(); }
    });
  }

  window.Reader = {
    configure(c) {
      const anchor = ready ? lastOffset : null;
      cfg = c;
      applyStyle();
      if (ready) requestAnimationFrame(() => { apply(anchor != null ? { textOffset: anchor } : { progression: 0 }); report(); });
    },
    go(target) { if (ready) { apply(target); report(); } else { pendingTarget = target; } },
    next() {
      if (cfg.layout === 'paginated') {
        if (page < pageCount() - 1) { goToPage(page + 1, true); return true; }
        return false;
      }
      if (cfg.layout === 'fixed') return false;
      const top = se().scrollTop;
      if (top >= maxScrollTop() - 2) return false;
      se().scrollBy({ top: H() - 80, behavior: 'smooth' });
      return true;
    },
    prev() {
      if (cfg.layout === 'paginated') {
        if (page > 0) { goToPage(page - 1, true); return true; }
        return false;
      }
      if (cfg.layout === 'fixed') return false;
      if (se().scrollTop <= 2) return false;
      se().scrollBy({ top: -(H() - 80), behavior: 'smooth' });
      return true;
    },
    setHighlights,
    find,
    clearSelection() { window.getSelection().removeAllRanges(); },
    chapterText() { return document.body.innerText || ''; },
    textAround(offset, radius) { const t = document.body.textContent || ''; return t.substr(Math.max(0, offset - radius), radius * 2); },
    snippetAt(offset) { return snippet(offset); },
    selectionRect() { const s = window.getSelection(); return s.rangeCount ? rectJSON(s.getRangeAt(0).getBoundingClientRect()) : null; },
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
