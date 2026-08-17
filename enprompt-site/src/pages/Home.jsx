import { useEffect } from 'react'
import BgOrbs from '../components/BgOrbs'
import Cubes from '../components/Cubes'
import Nav from '../components/Nav'
import Footer from '../components/Footer'
import CopyButton from '../components/CopyButton'
import { useRevealOnScroll } from '../hooks/useRevealOnScroll'

const INSTALL_CMD =
  'curl -L -o ~/Downloads/enprompt-1.9.4.dmg https://github.com/aadityakumarsah/enprompt/releases/download/v1.9.4/enprompt-1.9.4.dmg && open ~/Downloads/enprompt-1.9.4.dmg'

const FEATURES = [
  {
    icon: '✦',
    title: 'Expand your text',
    body: (
      <>
        Double-tap <span className="k">⌥</span> while typing anywhere — Notes, Slack, Chrome, Terminal — and
        enprompt reads the focused text field via the Accessibility API, sends your exact words to the model,
        and writes the result back in place. Grammar, spelling, punctuation, and flow are fixed; your meaning,
        intent, and tone are preserved exactly. The prompt contract is strict: output-only, no commentary, no
        markdown, no invented facts — and every edit is recorded, so <span className="k">⌘</span>+<span className="k">Z</span>{' '}
        restores the original even in apps with no undo support.
      </>
    ),
  },
  {
    icon: '🎙',
    title: 'Dictate by holding ⌥',
    body: (
      <>
        Hold <span className="k">⌥</span> for 1.25 seconds and a speech-recognition session starts — on-device,
        in 40+ languages, with a live transcript preview on screen. Release the key and your words are inserted
        at the cursor, then LLM-corrected in the same pass for punctuation and phrasing. No new windows, no tab
        switches, no clipboard dance: the text lands exactly where you were typing.
      </>
    ),
  },
  {
    icon: '✏️',
    title: 'Draw & capture',
    body: (
      <>
        Triple-tap <span className="k">⌥</span> to overlay a full-screen canvas above whatever you're working
        on. Circle, box, or scribble the element you mean with pen, shapes, or a laser pointer that fades as you
        move — and speak the change you want. Press Esc and enprompt sends the annotated screenshot plus your
        spoken instruction to a vision-capable model, then pastes one precise, self-contained prompt into your
        editor and saves it to history.
      </>
    ),
  },
  {
    icon: '↩',
    title: 'One-tap replies',
    body: (
      <>
        Choose a register from built-in presets — X posts, founder replies, email, concise, ultra-detailed,
        academic — select any text, and double-tap <span className="k">⌥</span>. enprompt rewrites it into a
        natural reply in that style, in your voice: no hashtag spam, no filler, no markdown, just the reply text
        ready to send.
      </>
    ),
  },
  {
    icon: '↺',
    title: 'Instant undo',
    body: (
      <>
        Every enhancement snapshots the exact pre-edit state, so <span className="k">⌘</span>+<span className="k">Z</span>{' '}
        within 30 seconds restores your original text character-for-character — even in apps that can't undo,
        like Terminal and custom editors. The shortcut is intercepted and swallowed, so it never leaks into the
        host application as an unwanted undo.
      </>
    ),
  },
  {
    icon: '🔒',
    title: 'Private by design',
    body: (
      <>
        Your API key lives in the macOS Keychain — never in files or defaults. Speech is transcribed on-device,
        not in the cloud. enprompt is a single ~3 MB menu-bar agent with no account, no telemetry, and no
        tracking: the only bytes that leave your Mac are the text you explicitly choose to send to your provider.
      </>
    ),
  },
]

const STEPS = [
  {
    num: '01',
    glyph: <span className="key">⌥</span>,
    title: 'Expand',
    body: 'Type something rough. Double-tap ⌥. Your text comes back polished — same meaning, better words.',
  },
  {
    num: '02',
    glyph: <span className="key hold">⌥ hold 1.25s</span>,
    title: 'Dictate',
    body: 'Hold ⌥, speak your thought, release. No tabs to open, no windows to switch — the text just appears.',
  },
  {
    num: '03',
    glyph: (
      <>
        <span className="key">⌥</span>
        <span className="key">⌥</span>
        <span className="key">⌥</span>
      </>
    ),
    title: 'Capture',
    body: 'Triple-tap ⌥, circle the bug on your screen, say what to fix, hit Esc. A perfect prompt is pasted into your input and saved to history.',
  },
]

export default function Home() {
  useRevealOnScroll()

  // Feature-card spotlight + macbook parallax (was script.js).
  useEffect(() => {
    const cards = Array.from(document.querySelectorAll('.feature-card'))
    const onMove = (e) => {
      const rect = e.currentTarget.getBoundingClientRect()
      e.currentTarget.style.setProperty('--mx', e.clientX - rect.left + 'px')
      e.currentTarget.style.setProperty('--my', e.clientY - rect.top + 'px')
    }
    cards.forEach((card) => card.addEventListener('pointermove', onMove))

    const macbook = document.getElementById('macbook')
    const demoSection = macbook?.closest('.demo')
    const onDemoMove = (e) => {
      const rect = demoSection.getBoundingClientRect()
      const dx = (e.clientX - rect.left) / rect.width - 0.5
      const dy = (e.clientY - rect.top) / rect.height - 0.5
      macbook.style.transform =
        'rotateY(' + (dx * 10).toFixed(2) + 'deg) rotateX(' + (-dy * 8).toFixed(2) + 'deg)'
    }
    const onDemoLeave = () => {
      macbook.style.transform = 'rotateY(0deg) rotateX(0deg)'
    }
    if (macbook && demoSection) {
      demoSection.addEventListener('pointermove', onDemoMove)
      demoSection.addEventListener('pointerleave', onDemoLeave)
    }

    return () => {
      cards.forEach((card) => card.removeEventListener('pointermove', onMove))
      if (macbook && demoSection) {
        demoSection.removeEventListener('pointermove', onDemoMove)
        demoSection.removeEventListener('pointerleave', onDemoLeave)
      }
    }
  }, [])

  return (
    <>
      <BgOrbs />
      <Cubes />
      <Nav />

      <header id="top" className="hero">
        <div className="hero-inner">
          <img src="/assets/icon.png" alt="enprompt" className="hero-logo" />
          <h1 className="hero-title">
            Write, dictate, and draw
            <span className="gradient-text">from one key.</span>
          </h1>
          <p className="hero-sub">
            enprompt lives in your menu bar — double-tap <span className="k">⌥</span> to expand any text,
            hold <span className="k">⌥</span> to dictate, or triple-tap <span className="k">⌥</span> to turn
            what's on your screen into the perfect prompt — then draw and annotate right on it.
          </p>
          <div className="hero-actions">
            <CopyButton
              text={INSTALL_CMD}
              label={
                <>
                  <span className="terminal-icon">&gt;_</span> Copy install command
                </>
              }
            />
            <a href="#download" className="btn btn-soft">
              See install steps <span className="down-arrow">⌄</span>
            </a>
          </div>
          <div className="hero-meta">
            <span>macOS 14+</span>
            <span className="meta-dot">·</span>
            <span>~3 MB</span>
            <span className="meta-dot">·</span>
            <span>1,200+ downloads</span>
            <span className="meta-dot">·</span>
            <span>100% free</span>
          </div>
        </div>
      </header>

      <section id="demo" className="demo">
        <div className="demo-inner">
          <div className="section-head">
            <span className="section-tag">See it in action</span>
            <h2>Your words, upgraded — live</h2>
            <p>Watch enprompt rewrite, dictate, and capture in real time on a MacBook Air.</p>
          </div>
          <div className="macbook" id="macbook">
            <div className="macbook-screen">
              <div className="macbook-camera"></div>
              <div className="window-bar">
                <span className="window-dot red"></span>
                <span className="window-dot yellow"></span>
                <span className="window-dot green"></span>
                <span className="window-title">enprompt — demo</span>
              </div>
              <div className="video-wrap">
                <video className="demo-video" autoPlay muted loop playsInline preload="metadata">
                  <source src="/assets/demo.mp4" type="video/mp4" />
                </video>
              </div>
            </div>
            <div className="macbook-base">
              <div className="macbook-notch"></div>
              <div className="macbook-keyboard"></div>
            </div>
            <div className="macbook-shadow"></div>
          </div>
        </div>
      </section>

      <div className="marquee">
        <div className="marquee-track">
          {[0, 1].map((dup) => (
            <span key={dup}>
              <span>✦&nbsp; Expand</span><span>✦&nbsp; Dictate</span><span>✦&nbsp; Annotate</span>
              <span>✦&nbsp; Undo</span><span>✦&nbsp; Presets</span><span>✦&nbsp; Private</span>
              <span>✦&nbsp; Instant</span><span>✦&nbsp; Every app</span>
            </span>
          ))}
        </div>
      </div>

      <section id="features" className="features">
        <div className="section-head">
          <span className="section-tag">Features</span>
          <h2>Everything you type, perfected</h2>
          <p>Three gestures. Infinite superpowers. enprompt never leaves your menu bar.</p>
        </div>
        <div className="feature-grid">
          {FEATURES.map((f) => (
            <div className="feature-card reveal" data-icon={f.icon} key={f.title}>
              <div className="feature-icon">{f.icon}</div>
              <h3>{f.title}</h3>
              <p>{f.body}</p>
            </div>
          ))}
        </div>
      </section>

      <section id="how" className="how">
        <div className="section-head">
          <span className="section-tag">How it works</span>
          <h2>Three gestures. One workflow.</h2>
        </div>
        <div className="steps">
          {STEPS.map((s, i) => (
            <div key={s.num} style={{ display: 'contents' }}>
              <div className="step reveal">
                <div className="step-num">{s.num}</div>
                <div className="step-glyph">{s.glyph}</div>
                <h3>{s.title}</h3>
                <p>{s.body}</p>
              </div>
              {i < STEPS.length - 1 && <div className="step-arrow">→</div>}
            </div>
          ))}
        </div>
      </section>

      <section id="setup" className="setup">
        <div className="setup-inner">
          <div className="section-head">
            <span className="section-tag">Setup</span>
            <h2>60 seconds. One time. Done.</h2>
            <p>enprompt walks you through permissions once — then restarts itself when you're done. No more configuration, ever.</p>
          </div>
          <div className="setup-grid">
            <div className="setup-card reveal">
              <div className="setup-check">✓</div>
              <h3>Accessibility</h3>
              <p>Reads & writes text in any app, and powers the global ⌥ hotkeys.</p>
            </div>
            <div className="setup-card reveal">
              <div className="setup-check">✓</div>
              <h3>Screen Recording</h3>
              <p>For the drawing canvas. The moment you allow it, enprompt restarts itself automatically.</p>
            </div>
            <div className="setup-card reveal">
              <div className="setup-check">✓</div>
              <h3>Microphone</h3>
              <p>Push-to-talk dictation and canvas voice — requested up-front, never mid-flow.</p>
            </div>
            <div className="setup-card reveal">
              <div className="setup-check">✓</div>
              <h3>Speech Recognition</h3>
              <p>On-device transcription so your words land at the cursor, private and fast.</p>
            </div>
          </div>
          <div className="provider-strip reveal">
            <span className="provider-label">Works with</span>
            <span className="provider">Gemini</span><span className="dot">·</span>
            <span className="provider">Claude</span><span className="dot">·</span>
            <span className="provider">OpenAI</span><span className="dot">·</span>
            <span className="provider">OpenRouter</span>
            <span className="provider-note">— just paste your API key. enprompt detects the provider, validates the key, and saves it to your Keychain.</span>
          </div>
        </div>
      </section>

      <section id="download" className="cta">
        <div className="cta-inner reveal">
          <img src="/assets/icon.png" alt="enprompt" className="cta-icon" />
          <h2>Make your writing effortless.</h2>
          <p>Free forever. No account. No tracking. Just a wand in your menu bar.</p>
          <div className="hero-guide" style={{ margin: '0 auto 34px' }}>
            <div className="guide-step">
              <span className="guide-num">1</span>
              <p>Click <b>Copy install command</b> above — the install command is copied to your clipboard.</p>
            </div>
            <div className="guide-step">
              <span className="guide-num">2</span>
              <p>Open <b>Terminal</b>, paste with <span className="k">⌘</span>+<span className="k">V</span>
                <img src="/assets/icon.png" alt="enprompt" className="guide-logo" />, and press <b>Return</b>.</p>
            </div>
            <div className="guide-step">
              <span className="guide-num">3</span>
              <p>enprompt downloads and opens — drag it into <b>Applications</b>.</p>
            </div>
          </div>
          <div className="hero-actions">
            <CopyButton text={INSTALL_CMD} label="Copy install command" className="btn btn-primary" />
            <a href="#how" className="btn btn-ghost">Learn the gestures</a>
          </div>
          <div className="install-box">
            <code id="install-cmd">{INSTALL_CMD}</code>
            <span id="install-copied" className="install-copied" hidden>Copied! Paste it in Terminal.</span>
          </div>
          <p className="cta-note">
            macOS 14+ · Apple Silicon · ~3 MB · open source on{' '}
            <a href="https://github.com/aadityakumarsah/enprompt" target="_blank" rel="noopener">GitHub</a>
          </p>
        </div>
      </section>

      <Footer />
    </>
  )
}
