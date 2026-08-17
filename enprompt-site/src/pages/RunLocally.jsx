import { Link } from 'react-router-dom'
import BgOrbs from '../components/BgOrbs'
import Nav from '../components/Nav'
import Footer from '../components/Footer'
import CommandLine from '../components/CommandLine'
import { useRevealOnScroll } from '../hooks/useRevealOnScroll'

const BENCHMARKS = [
  { model: 'llama3.2', disk: '2.0 GB', ram: '8 GB', speed: '~45', better: 'base', enhance: true, vision: false, cost: '—', best: 'Everyday text enhance — fastest, lightest', pick: true },
  { model: 'llama3.2-vision', disk: '7.9 GB', ram: '16 GB', speed: '~20', better: '+0', enhance: true, vision: true, cost: '—', best: 'Recommended vision — screenshots + annotations', pick: true },
  { model: 'llama3.1:8b', disk: '4.9 GB', ram: '16 GB', speed: '~25', better: '+9', enhance: true, vision: false, cost: '—', best: 'Higher-quality text enhance on 16 GB Macs' },
  { model: 'gemma3:4b', disk: '3.3 GB', ram: '8 GB', speed: '~38', better: '-9', enhance: true, vision: true, cost: '—', best: 'Both jobs with one small model' },
  { model: 'qwen2.5vl:7b', disk: '6.0 GB', ram: '16 GB', speed: '~22', better: '+5', enhance: true, vision: true, cost: '—', best: 'Vision alternative — great at reading UIs' },
  { model: 'llava:7b', disk: '4.7 GB', ram: '16 GB', speed: '~20', better: '-5', enhance: true, vision: true, cost: '—', best: 'Light vision capture' },
  { model: 'qwen3:8b', disk: '5.2 GB', ram: '16 GB', speed: '~28', better: '+24', enhance: true, vision: false, cost: '—', best: 'Best-quality text enhance on 16 GB Macs' },
  { model: 'deepseek-r1:8b', disk: '4.9 GB', ram: '16 GB', speed: '~25', better: '+18', enhance: true, vision: false, cost: '—', best: 'Reasoning-style rewrites' },
]

const CLOUD = [
  { model: 'Claude (Sonnet)', provider: 'Anthropic', disk: '—', ram: '—', speed: '~50–80', better: '+67', enhance: true, vision: true, cost: 'pay per token', best: 'Best overall quality — polish & long rewrites' },
  { model: 'Codex', provider: 'OpenAI', disk: '—', ram: '—', speed: '~50–80', better: '+64', enhance: true, vision: true, cost: 'pay per token', best: 'Best for technical text, plans & structured output' },
  { model: 'Gemini (2.5 Pro)', provider: 'Google', disk: '—', ram: '—', speed: '~50–100', better: '+60', enhance: true, vision: true, cost: 'free tier', best: 'Free tier via Google AI Studio — try before you pay' },
]

export default function RunLocally() {
  useRevealOnScroll()

  return (
    <>
      <BgOrbs />
      <Nav />

      <header className="local-hero">
        <img src="/assets/icon.png" alt="enprompt" className="hero-logo" />
        <h1>
          Run <span className="gradient-text">Llama models</span> on your Mac.
        </h1>
        <p>
          No API key. No account. No money. Meta's Llama runs locally through the free Ollama engine —
          every word you enhance and every screen you capture stays on your machine, even offline.
        </p>
        <div className="local-meta">
          <span>🔒 <b>Private</b> — zero data leaves your Mac</span>
          <span>🆓 <b>Free forever</b> — no subscriptions</span>
          <span>📴 <b>Works offline</b></span>
          <span>💾 ~10 GB disk for the recommended Llama set</span>
        </div>
      </header>

      <div className="local-wrap">

        <div className="opt" id="setup">
          <div className="opt-head">
            <span className="opt-badge badge-free">Recommended · free · local</span>
            <h2>Llama on your Mac — how it works</h2>
          </div>
          <p className="opt-sub">
            Llama models are downloaded and run by <b>Ollama</b>, a free engine (think of it as the
            "app store + runner" for open models). enprompt detects it automatically — in Settings, the{' '}
            <b>"Run locally — free &amp; private (guide)"</b> button in the LLM section opens this page,
            and the Ollama models section does everything for you: <b>one click installs the Ollama app
            itself (if missing), starts it, and pulls both models</b> — no terminal, no browser, no
            drag-and-drop. Everything below is the manual path only:
          </p>
          <div className="steps">
            <div className="step-card">
              <div>
                <h3>Install the Ollama engine (one command, ~1 minute)</h3>
                <p>
                  No admin password, no account. Or download the app from{' '}
                  <a href="https://ollama.com/download" target="_blank" rel="noopener">ollama.com/download</a>.
                </p>
                <CommandLine id="cmd-install" text="curl -fsSL https://ollama.com/install.sh | sh" />
              </div>
            </div>
            <div className="step-card">
              <div>
                <h3>Start Ollama</h3>
                <p>
                  Launch the <b>Ollama</b> app from your Applications folder (or the menu bar llama icon).
                  It must be running while enprompt works.
                </p>
              </div>
            </div>
            <div className="step-card">
              <div>
                <h3>Pull the two recommended Llama models</h3>
                <p>
                  One handles text, one handles images (screen capture). Or skip the terminal entirely —
                  enprompt downloads both at the same time with a live progress bar.
                </p>
                <CommandLine
                  id="cmd-pull-enhance"
                  text="ollama pull llama3.2"
                  hint="Text enhancement (double-tap ⌥) — ≈ 2.0 GB · runs on 8 GB RAM Macs"
                />
                <CommandLine
                  id="cmd-pull-vision"
                  text="ollama pull qwen2.5vl:7b"
                  hint="Vision — image / screen capture (triple-tap ⌥) — ≈ 6.0 GB · needs 16 GB RAM"
                />
              </div>
            </div>
            <div className="step-card">
              <div>
                <h3>Point enprompt at it</h3>
                <p>
                  Open enprompt → <b>Settings… → LLM → Change</b> → pick <b>Ollama (local)</b> → the server (
                  <span className="mono">http://127.0.0.1:11434/v1</span>) and key (
                  <span className="mono">ollama</span> — a sentinel, there is no real key) fill themselves →{' '}
                  <b>Save</b>. enprompt lists your pulled models and auto-selects the first vision-capable
                  one for capture.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">Pick your power level</span>
            <h2>Benchmarks — local vs cloud, what fits your Mac</h2>
          </div>
          <p className="opt-sub">
            Local sizes are disk space after download (Q4 quantization), speeds are approximate generation
            rates on Apple Silicon (M1–M4 class), and RAM is what the Mac should have.{' '}
            <span className="tick">✓</span> = supported. <b>% better</b> is a rough quality estimate for
            writing &amp; enhancement work compared to the <span className="mono">llama3.2</span> baseline —
            a feel for real-world results, not a formal benchmark. Cloud speeds assume a decent connection —
            you pay per token, but download nothing and use no RAM. The full local library lives at{' '}
            <a href="https://ollama.com/library" target="_blank" rel="noopener">ollama.com/library</a> — pull
            anything new with <span className="mono">ollama pull &lt;name&gt;</span>, hit{' '}
            <b>Refresh models</b> in enprompt, and it appears instantly.
          </p>
          <div className="bench-wrap">
          <table className="bench">
            <thead>
              <tr>
                <th>Model</th>
                <th>Disk space</th>
                <th>Mac RAM</th>
                <th>Speed (tok/s)</th>
                <th>% better</th>
                <th>Enhance</th>
                <th>Vision</th>
                <th>Cost</th>
                <th>Best for</th>
              </tr>
            </thead>
            <tbody>
              {BENCHMARKS.map((b) => (
                <tr key={b.model} className={b.pick ? 'pick' : undefined}>
                  <td className="mono">{b.model}</td>
                  <td>{b.disk}</td>
                  <td>{b.ram}</td>
                  <td>{b.speed}</td>
                  <td>
                    {b.better === 'base' ? (
                      <span className="base">baseline</span>
                    ) : b.better.startsWith('+') ? (
                      <span className="up">+{b.better.slice(1)}%</span>
                    ) : (
                      <span className="down">{b.better}%</span>
                    )}
                  </td>
                  <td>{b.enhance ? <span className="tick">✓</span> : <span className="cross">—</span>}</td>
                  <td>{b.vision ? <span className="tick">✓</span> : <span className="cross">—</span>}</td>
                  <td>{b.cost}</td>
                  <td>{b.best}</td>
                </tr>
              ))}
              <tr className="group">
                <td colSpan="9">
                  Cloud models — same enprompt, nothing to download · paste a key in Settings → LLM
                </td>
              </tr>
              {CLOUD.map((c) => (
                <tr key={c.model}>
                  <td className="mono">
                    {c.model}
                    <span className="provider-mini">{c.provider}</span>
                  </td>
                  <td>{c.disk}</td>
                  <td>{c.ram}</td>
                  <td>{c.speed}</td>
                  <td><span className="up">+{c.better}%</span></td>
                  <td>{c.enhance ? <span className="tick">✓</span> : <span className="cross">—</span>}</td>
                  <td>{c.vision ? <span className="tick">✓</span> : <span className="cross">—</span>}</td>
                  <td>{c.cost}</td>
                  <td>{c.best}</td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
          <p className="note">
            Highlighted = the recommended Llama pair. Cloud rows need an API key — Claude, Codex/OpenAI and
            Gemini all work out of the box: Settings → LLM → pick the provider, paste the key (Gemini has a
            free tier via Google AI Studio), set the Model + Server URL fields if your provider asks for
            them. No disk space, no RAM, no downloads — but you do send your text to that provider.
          </p>
        </div>

        <div className="cta-local">
          <h2>Two minutes, zero dollars.</h2>
          <p>
            Install enprompt, run Llama locally with Ollama, and every ⌥ superpower works — private, free,
            and offline.
          </p>
          <a href="/#download" className="btn btn-primary">Get enprompt (free)</a>
          <Link to="/" className="btn btn-ghost">← Back to overview</Link>
        </div>

      </div>

      <Footer />
    </>
  )
}
