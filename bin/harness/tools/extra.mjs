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
