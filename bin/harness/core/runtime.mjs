// Salenta Harness – Laufzeit
// Alles, was der Agent kann, hängt an benannten Bausteinen (Anbieter, Werkzeuge, Richtlinie, Ausgabe).
// Erweiterungen melden sich über `use(plugin)` an und können Bausteine ersetzen oder Werkzeuge ergänzen –
// der Kern kennt nur die Schlüssel, nicht die konkrete Umsetzung.

export function createRuntime(options = {}) {
  const services = new Map()
  const tools = new Map()
  const hooks = { beforeTool: [], afterTool: [], beforeModel: [], afterStep: [] }
  const plugins = []

  const rt = {
    options,
    /** Baustein bereitstellen (überschreibt einen vorhandenen mit demselben Schlüssel). */
    provide(key, impl) { services.set(key, impl); return rt },
    /** Baustein holen – wirft, wenn er fehlt, damit Fehler früh und verständlich auftauchen. */
    get(key) {
      if (!services.has(key)) throw new Error(`Baustein fehlt: ${key}`)
      return services.get(key)
    },
    has(key) { return services.has(key) },

    /** Werkzeug anmelden: { name, label, description, parameters, readOnly, parallelSafe, run(args, ctx) } */
    tool(def) {
      if (!def?.name || typeof def.run !== 'function') throw new Error('Werkzeug braucht name und run()')
      tools.set(def.name, { readOnly: false, parallelSafe: false, ...def })
      return rt
    },
    removeTool(name) { tools.delete(name); return rt },
    tools(filter = () => true) { return [...tools.values()].filter(filter) },
    toolByName(name) { return tools.get(name) },

    /** Ereignis-Haken: beforeTool(call, ctx) darf { deny: 'Grund' } liefern; afterTool/afterStep beobachten. */
    on(event, fn) { (hooks[event] ||= []).push(fn); return rt },
    async emit(event, ...args) {
      for (const fn of hooks[event] || []) {
        const r = await fn(...args)
        if (r && r.deny) return r
      }
      return null
    },

    /** Erweiterung laden: Funktion (rt) => void, oder Objekt mit register(rt). */
    use(plugin) {
      const fn = typeof plugin === 'function' ? plugin : plugin?.register
      if (typeof fn !== 'function') throw new Error('Erweiterung braucht register(rt)')
      fn(rt)
      plugins.push(plugin?.name || fn.name || 'plugin')
      return rt
    },
    plugins() { return [...plugins] },
  }
  return rt
}
