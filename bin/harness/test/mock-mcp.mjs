// Kleiner MCP-Server für die Tests: „browser_click“ protokolliert Klicks, „freigabe“ lehnt alles mit „kaufen“ ab.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const role = process.argv[2] || 'browser'
const tools = role === 'salenta-os'
  ? [{ name: 'freigabe', description: 'Freigabe', inputSchema: { type: 'object', properties: { tool_name: { type: 'string' }, input: { type: 'object' } } } },
     { name: 'lage', description: 'Lage', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true } }]
  : [{ name: 'browser_click', description: 'Klick', inputSchema: { type: 'object', properties: { element: { type: 'string' } }, required: ['element'] } },
     { name: 'browser_snapshot', description: 'Seite als Text', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true } }]
const send = m => process.stdout.write(JSON.stringify(m) + '\n')
const text = t => ({ content: [{ type: 'text', text: t }] })

createInterface({ input: process.stdin }).on('line', line => {
  let m; try { m = JSON.parse(line) } catch { return }
  if (m.id === undefined) return
  if (m.method === 'initialize') return send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: role, version: '1' } } })
  if (m.method === 'tools/list') return send({ jsonrpc: '2.0', id: m.id, result: { tools } })
  if (m.method === 'tools/call') {
    const { name, arguments: a = {} } = m.params
    if (name === 'freigabe') {
      const deny = JSON.stringify(a.input || {}).toLowerCase().includes('kaufen')
      if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, `freigabe ${a.tool_name}\n`)
      return send({ jsonrpc: '2.0', id: m.id, result: text(JSON.stringify(deny ? { behavior: 'deny', message: 'Kaufen braucht dich.' } : { behavior: 'allow', updatedInput: a.input })) })
    }
    if (name === 'browser_click') { if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, `klick ${a.element}\n`); return send({ jsonrpc: '2.0', id: m.id, result: text('geklickt') }) }
    if (name === 'browser_snapshot') return send({ jsonrpc: '2.0', id: m.id, result: text('- button "OK"') })
    return send({ jsonrpc: '2.0', id: m.id, result: text('ok') })
  }
  send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'unbekannt' } })
})
