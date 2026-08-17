import { Link } from 'react-router-dom'
import BgOrbs from '../components/BgOrbs'
import Nav from '../components/Nav'
import Footer from '../components/Footer'
import { useRevealOnScroll } from '../hooks/useRevealOnScroll'

const TOPICS = [
  {
    to: '/learn/system-prompt',
    icon: '🧠',
    tag: 'Beginner friendly',
    title: 'System prompts, explained',
    body:
      'The hidden instructions that make enprompt write like an elite engineer, a real founder, or a sharp X/Twitter reply — what they are, what the built-in presets do, and how to pick the right one.',
    cta: 'Open the guide →',
  },
  {
    to: '/learn/system-prompt',
    icon: '🐦',
    tag: 'Preset deep-dive',
    title: 'X.com reply — sound like a builder',
    body:
      'Reply to founders and technical leaders with one sharp, human sentence that adds real engineering value. Never sounds like a job seeker, never like a bot.',
    cta: 'See how it works →',
  },
  {
    to: '/learn/system-prompt',
    icon: '✉️',
    tag: 'Preset deep-dive',
    title: 'Email reply — earn the reply',
    body:
      'Write concise, technically credible emails to founders, CTOs, and hiring managers. Direct, warm, and sharp — with a clear next step that invites the conversation.',
    cta: 'See how it works →',
  },
  {
    to: '/learn/system-prompt',
    icon: '🚀',
    tag: 'Preset deep-dive',
    title: 'Founder reply — be the real founder',
    body:
      'Reply to customers, reviews, and DMs as the actual person building the company. Warm, honest, understated — never corporate, never marketing.',
    cta: 'See how it works →',
  },
]

export default function Learn() {
  useRevealOnScroll()

  return (
    <>
      <BgOrbs />
      <Nav />

      <header className="local-hero">
        <img src="/assets/icon.png" alt="enprompt" className="hero-logo" />
        <h1>
          Learn enprompt, <span className="gradient-text">the right way.</span>
        </h1>
        <p>
          Short, practical guides for getting the most out of enprompt. Start with the system prompts —
          the hidden instructions that turn ⌥⌥ into an elite reply writer.
        </p>
        <div className="local-meta">
          <span>📖 <b>Free guides</b> — read in minutes</span>
          <span>⚡ <b>Practical</b> — copy-paste-ready</span>
          <span>🎯 <b>Real use</b> — X, email, customers</span>
        </div>
      </header>

      <div className="local-wrap">
        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">Start here</span>
            <h2>All topics</h2>
          </div>
          <div className="learn-grid">
            {TOPICS.map((t, i) => (
              <Link to={t.to} className="learn-card reveal" key={t.to + i}>
                <div className="learn-icon">{t.icon}</div>
                <span className="learn-tag">{t.tag}</span>
                <h3>{t.title}</h3>
                <p>{t.body}</p>
                <span className="learn-cta">{t.cta}</span>
              </Link>
            ))}
          </div>
        </div>

        <div className="cta-local reveal">
          <h2>Still need the app?</h2>
          <p>
            enprompt lives in your menu bar — double-tap ⌥ to expand text, hold it to dictate, triple-tap
            to draw over your screen. The presets above are built in.
          </p>
          <a href="/#download" className="btn btn-primary">Get enprompt (free)</a>
          <Link to="/" className="btn btn-ghost">← Back to overview</Link>
        </div>
      </div>

      <Footer />
    </>
  )
}