// Plan (Aufgabenliste des Agents) und Webseiten lesen.

export function planTool(rt) {
  rt.tool({
    name: 'plan', label: 'TodoWrite', readOnly: true,
    description: 'Keep a short plan for multi-step work. Send the full list each time; status is pending, in_progress or completed. Exactly one item in_progress while working.',
    parameters: {
      type: 'object',
      properties: { items: { type: 'array', items: { type: 'object', properties: { content: { type: 'string' }, status: { type: 'string', enum: ['pending', 'in_progress', 'completed'] } }, required: ['content', 'status'] } } },
      required: ['items'],
    },
    run({ items = [] }, ctx) {
      ctx.session.append('plan', { items })
      const open = items.filter(i => i.status !== 'completed').length
      return { output: `Plan gespeichert: ${items.length} Punkte, ${open} offen.` }
    },
  })
}

function htmlToText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<(br|p|div|li|h[1-6]|tr)[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16))).replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n\n').trim()
}

export function webTool(rt) {
  rt.tool({
    name: 'web_fetch', label: 'WebFetch', readOnly: true, parallelSafe: true,
    description: 'Fetch a public web page or API (GET) and return its readable text. Use for docs and references.',
    parameters: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] },
    async run({ url }, ctx) {
      if (!/^https?:\/\//i.test(url)) return { error: 'Nur http(s)-Adressen.' }
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(30_000), headers: { 'user-agent': 'salenta-harness' } })
        const type = res.headers.get('content-type') || ''
        let body = await res.text()
        if (type.includes('html')) body = htmlToText(body)
        if (body.length > 40_000) body = body.slice(0, 40_000) + '\n… (gekürzt)'
        return res.ok ? { output: body } : { error: `HTTP ${res.status}\n${body.slice(0, 2000)}` }
      } catch (e) { return { error: `Nicht erreichbar: ${e.message}` } }
    },
  })
}

/** Websuche ohne Schlüssel (HTML-Ergebnisseite einer Suchmaschine). Liefert Titel, Adresse und Kurztext. */
export function parseSearch(html) {
  const out = []
  const re = /<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>([\s\S]*?)(?=<a[^>]*class="result__a"|$)/g
  let m
  while ((m = re.exec(html)) && out.length < 8) {
    let url = m[1].replace(/&amp;/g, '&')
    const u = /[?&]uddg=([^&]+)/.exec(url)
    if (u) url = decodeURIComponent(u[1])
    if (url.startsWith('//')) url = 'https:' + url
    const snip = /class="result__snippet"[^>]*>([\s\S]*?)<\/a>/.exec(m[3])
    out.push({ title: htmlToText(m[2]), url, snippet: snip ? htmlToText(snip[1]) : '' })
  }
  return out
}

export function searchTool(rt) {
  rt.tool({
    name: 'web_search', label: 'WebSearch', readOnly: true, parallelSafe: true,
    description: 'Search the web. Returns up to 8 results (title, address, short text). Follow up with web_fetch to read a result. Never put names, e-mail addresses or project secrets into a query.',
    parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] },
    async run({ query }) {
      if (!String(query || '').trim()) return { error: 'Suchbegriff fehlt.' }
      try {
        const res = await fetch('https://html.duckduckgo.com/html/?q=' + encodeURIComponent(query), { signal: AbortSignal.timeout(25_000), headers: { 'user-agent': 'Mozilla/5.0 (compatible; salenta-harness)' } })
        const hits = parseSearch(await res.text())
        if (!hits.length) return { error: 'Keine Treffer oder Suche gerade nicht erreichbar. Nutze web_fetch mit einer bekannten Adresse (z. B. der offiziellen Dokumentation).' }
        return { output: hits.map((h, i) => `${i + 1}. ${h.title}\n   ${h.url}\n   ${h.snippet}`).join('\n') }
      } catch (e) { return { error: `Suche nicht erreichbar: ${e.message}` } }
    },
  })
}
