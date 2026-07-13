// Sources/IqraReader/ReaderAssets/bridge.js
// The ONLY channel between book content and the app (spec: Thorium's preload pattern).
// Runs as a module in the reader page; talks to Swift via webkit.messageHandlers.iqra.
import './vendor/foliate-js/view.js'
import { EPUB } from './vendor/foliate-js/epub.js'
import { configure, ZipReader, BlobReader, TextWriter, BlobWriter } from './vendor/foliate-js/vendor/zip.js'

const post = payload => window.webkit?.messageHandlers?.iqra?.postMessage(payload)
window.addEventListener('error', e => post({ type: 'error', message: String(e.message) }))
window.addEventListener('unhandledrejection', e => post({ type: 'error', message: String(e.reason) }))

// Pure-JS SHA-1 (custom schemes are not secure contexts, so crypto.subtle is
// unavailable). Needed only for IDPF font deobfuscation. Input/output: ArrayBuffer.
const sha1 = async buffer => {
    const rotl = (n, b) => (n << b) | (n >>> (32 - b))
    const bytes = new Uint8Array(buffer)
    const ml = bytes.length
    const withPadding = new Uint8Array(((ml + 8) >> 6 << 6) + 64)
    withPadding.set(bytes)
    withPadding[ml] = 0x80
    const dv = new DataView(withPadding.buffer)
    dv.setUint32(withPadding.length - 4, ml << 3)
    dv.setUint32(withPadding.length - 8, ml / 0x20000000 | 0)
    let [h0, h1, h2, h3, h4] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    const w = new Uint32Array(80)
    for (let i = 0; i < withPadding.length; i += 64) {
        for (let j = 0; j < 16; j++) w[j] = dv.getUint32(i + j * 4)
        for (let j = 16; j < 80; j++) w[j] = rotl(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1)
        let [a, b, c, d, e] = [h0, h1, h2, h3, h4]
        for (let j = 0; j < 80; j++) {
            const [f, k] = j < 20 ? [(b & c) | (~b & d), 0x5A827999]
                : j < 40 ? [b ^ c ^ d, 0x6ED9EBA1]
                : j < 60 ? [(b & c) | (b & d) | (c & d), 0x8F1BBCDC]
                : [b ^ c ^ d, 0xCA62C1D6]
            const t = (rotl(a, 5) + f + e + k + w[j]) | 0
            e = d; d = c; c = rotl(b, 30); b = a; a = t
        }
        h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0
    }
    const out = new DataView(new ArrayBuffer(20))
    ;[h0, h1, h2, h3, h4].forEach((h, i) => out.setUint32(i * 4, h >>> 0))
    return out.buffer
}

const view = document.createElement('foliate-view')
document.body.append(view)
let sectionHrefs = []

view.addEventListener('relocate', e => {
    const { cfi, fraction, tocItem, section } = e.detail
    const spineIndex = section?.current ?? 0
    post({
        type: 'relocate',
        spineIndex,
        spineHref: sectionHrefs[spineIndex] ?? null,
        cfi: cfi ?? null,
        progressionInChapter: null, // section-level fraction is renderer-internal; display-only anyway
        totalProgression: fraction ?? 0,
        tocLabel: tocItem?.label ?? null,
    })
})

const flattenTOC = items => (items ?? []).map(({ label, href, subitems }) =>
    ({ label: label ?? '', href: href ?? null, subitems: subitems?.length ? flattenTOC(subitems) : null }))

const getCSS = s => [`
    @namespace epub "http://www.idpf.org/2007/ops";
    html { color-scheme: light dark; }
`, `
    html, body { color: ${s.theme.foreground} !important;
                 background: ${s.theme.background} !important; }
    html { font-size: ${s.fontSizePercent}% !important; }
    html, body, p, li, blockquote, dd {
        line-height: ${s.lineHeight} !important;
        text-align: ${s.justify ? 'justify' : 'start'};
    }
    ${s.fontFamily ? `html, body, p, li, blockquote, dd { font-family: ${s.fontFamily} !important; }` : ''}
`]

const applySettings = s => {
    view.renderer.setAttribute('flow', s.flow === 'scrolled' ? 'scrolled' : 'paginated')
    view.renderer.setStyles?.(getCSS(s))
}

window.iqra = {
    async start(config) {
        try {
            const res = await fetch('/book.epub')
            if (!res.ok) throw new Error(`book fetch failed: ${res.status}`)
            const blob = await res.blob()
            configure({ useWebWorkers: false })
            const reader = new ZipReader(new BlobReader(blob))
            const entries = await reader.getEntries()
            const map = new Map(entries.map(e => [e.filename, e]))
            const load = f => (name, ...args) =>
                map.has(name) ? map.get(name).getData(new f(...args)) : null
            const book = await new EPUB({
                loadText: load(TextWriter),
                loadBlob: name => map.has(name) ? map.get(name).getData(new BlobWriter()) : null,
                getSize: name => map.get(name)?.uncompressedSize ?? 0,
                sha1,
            }).init()
            await view.open(book)
            sectionHrefs = (book.sections ?? []).map(s => s.id ?? null)
            applySettings(config.settings)
            post({
                type: 'loaded',
                title: typeof book.metadata?.title === 'string'
                    ? book.metadata.title
                    : Object.values(book.metadata?.title ?? {})[0] ?? null,
                toc: flattenTOC(book.toc),
            })
            await view.init({ lastLocation: config.lastCFI ?? undefined, showTextStart: true })
        } catch (err) {
            post({ type: 'error', message: String(err?.message ?? err) })
        }
    },
    goTo: target => view.goTo(target),
    next: () => view.next(),
    prev: () => view.prev(),
    setAppearance: s => applySettings(s),
}

post({ type: 'ready' })
