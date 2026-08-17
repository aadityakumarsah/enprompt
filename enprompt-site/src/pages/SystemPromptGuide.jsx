import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import BgOrbs from '../components/BgOrbs'
import Nav from '../components/Nav'
import Footer from '../components/Footer'
import { useRevealOnScroll } from '../hooks/useRevealOnScroll'

const PRESETS = [
  {
    id: 'x',
    icon: '🐦',
    name: 'X.com (Twitter) reply',
    oneLine:
      'One sharp, human reply to a founder or technical leader that proves you actually build things.',
    bestFor: 'Replying to posts by founders, CTOs, and builders you want in your orbit.',
    avoids:
      'Generic praise ("great post!"), job-seeking hints, AI-bot tone, forced tool name-drops.',
    demo: {
      post: 'Just cut our API latency 40%. Turns out it was connection reuse, not the hot path.',
      reply:
        'Nice — that 40% hiding in connection reuse is the classic sleeper win. Curious what the failure mode looks like once traffic gets bursty, retries can quietly undo all of it.',
    },
  },
  {
    id: 'email',
    icon: '✉️',
    name: 'Email reply',
    oneLine:
      'A concise, technically credible email that makes a founder or CTO actually want to reply.',
    bestFor: 'Cold-ish emails, founder/CTO conversations, and technical threads you want to continue.',
    avoids:
      'Corporate filler ("Thank you for reaching out"), résumé paragraphs, invented experience.',
    demo: {
      post:
        'Hi — saw your work on AI infra. We\u2019re building a RAG pipeline at our startup and hitting latency walls as the index grows. Any thoughts?',
      reply:
        'Happy to dig in. The usual culprit as an index grows is re-ranking cost, not retrieval — a small two-stage setup usually buys a lot of headroom before you need to scale anything. Curious whether your latency budget is measured end-to-end or per-call. Would be interesting to compare notes.',
    },
  },
  {
    id: 'founder',
    icon: '🚀',
    name: 'Founder reply',
    oneLine:
      'Replies to customers, reviews, and DMs as the real person behind the company.',
    bestFor: 'Founders answering feedback, reviews, comments, and messages themselves.',
    avoids:
      'Customer-support scripts, marketing language, empty promises, "thank you so much!!!" energy.',
    demo: {
      post: 'Been using this for a few days. Onboarding is much smoother now.',
      reply:
        'Really glad it feels smoother — that was the area we wanted to make less painful. Still plenty to improve, but good signal.',
    },
  },
]

/** Types out a string char-by-char, then loops back to the beginning. */
function useTypewriter(text, speed = 28) {
  const [shown, setShown] = useState('')
  useEffect(() => {
    let i = 0
    let forward = true
    setShown('')
    const timer = setInterval(() => {
      if (forward) {
        i += 1
        setShown(text.slice(0, i))
        if (i >= text.length) {
          forward = false
        }
      } else {
        i -= 2
        if (i <= 0) {
          i = 0
          forward = true
        }
        setShown(text.slice(0, i))
      }
    }, speed)
    return () => clearInterval(timer)
  }, [text, speed])
  return shown
}

export default function SystemPromptGuide() {
  useRevealOnScroll()
  const typed = useTypewriter(PRESETS[0].demo.reply, 22)

  return (
    <>
      <BgOrbs />
      <Nav />

      <header className="local-hero">
        <img src="/assets/icon.png" alt="enprompt" className="hero-logo" />
        <h1>
          System prompts, <span className="gradient-text">explained.</span>
        </h1>
        <p>
          Every time you press <span className="k">⌥</span><span className="k">⌥</span>, enprompt sends your
          text to an LLM together with a <b>system prompt</b> — the hidden instruction that defines{' '}
          <i>who the model is</i> and <i>how it should write</i>. Pick the right one and enprompt stops
          being a generic rewriter and becomes an elite reply writer.
        </p>
      </header>

      <div className="local-wrap">

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">The idea</span>
            <h2>Same model, completely different writer</h2>
          </div>
          <p className="opt-sub">
            The system prompt is like a job description handed to the model before it sees your text.
            enprompt ships with three presets engineered for relationship-building — each one tells the
            model exactly <b>who to be</b>, <b>what to say</b>, and <b>what never to say</b>.
          </p>
          <div className="sp-steps">
            <div className="sp-step reveal">
              <span className="sp-step-n">1</span>
              <div>
                <h3>Select the preset</h3>
                <p>
                  Open enprompt → <b>Settings… → System Prompt</b> → pick{' '}
                  <b>X.com (Twitter) reply</b>, <b>Email reply</b>, or <b>Founder reply</b>.
                </p>
              </div>
            </div>
            <div className="sp-step reveal">
              <span className="sp-step-n">2</span>
              <div>
                <h3>Select the text</h3>
                <p>
                  In any app — X, Gmail, LinkedIn, Notes — select the post, email, or message you want
                  to reply to.
                </p>
              </div>
            </div>
            <div className="sp-step reveal">
              <span className="sp-step-n">3</span>
              <div>
                <h3>Double-tap ⌥</h3>
                <p>
                  enprompt reads the selected text, applies the preset, and writes the finished reply
                  back in place — ready to send.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">Live demo</span>
            <h2>What an elite reply feels like</h2>
          </div>
          <div className="sp-demo reveal">
            <div className="sp-demo-post">
              <span className="sp-demo-avatar">👤</span>
              <div>
                <b>Founder</b> <span className="sp-demo-handle">@buildingstuff</span>
                <p>{PRESETS[0].demo.post}</p>
              </div>
            </div>
            <div className="sp-demo-reply">
              <span className="sp-demo-avatar you">🧑‍💻</span>
              <div>
                <b>Your reply</b> <span className="sp-demo-handle">— X.com preset</span>
                <p>
                  {typed}
                  <span className="caret" />
                </p>
              </div>
            </div>
          </div>
          <p className="note">
            One insight, not a paragraph. The reply adds engineering value (retries undoing the win),
            asks a genuine technical question, and sounds like a human who ships software.
          </p>
        </div>

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">The presets</span>
            <h2>Pick your writer</h2>
          </div>

          {PRESETS.map((p, i) => (
            <div className="sp-preset reveal" key={p.id}>
              <div className="sp-preset-head">
                <span className="learn-icon">{p.icon}</span>
                <div>
                  <h3>{p.name}</h3>
                  <p>{p.oneLine}</p>
                </div>
              </div>
              <div className="sp-preset-cols">
                <div>
                  <b className="sp-label good">Best for</b>
                  <p>{p.bestFor}</p>
                  <b className="sp-label bad">Never does</b>
                  <p>{p.avoids}</p>
                </div>
                <div className="sp-preset-demo">
                  <b className="sp-label">Example</b>
                  <div className="sp-mini-post">“{p.demo.post}”</div>
                  <div className="sp-mini-reply">“{p.demo.reply}”</div>
                </div>
              </div>
            </div>
          ))}
        </div>

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">Out of the box</span>
            <h2>The default — one prompt, every user</h2>
          </div>
          <p className="opt-sub">
            Every enprompt install ships the <b>exact same default system prompt</b>: enprompt is defined as
            an AI prompt-engineering engine — it never answers, solves, or rewrites your request, it turns
            your rough developer request into a clear, precise, implementation-ready prompt for another AI
            coding agent. The contract is strict and identical for everyone: preserve intent, never invent
            requirements, structure instead of padding, and output only the enhanced prompt.
          </p>
          <div className="sp-steps">
            <div className="sp-step reveal">
              <span className="sp-step-n">1</span>
              <div>
                <h3>Same default for all</h3>
                <p>
                  Updates reset the stored prompt to the shared default — no user runs a stale or
                  divergent prompt. It's the "Polished rewrite (default)" preset in Settings.
                </p>
              </div>
            </div>
            <div className="sp-step reveal">
              <span className="sp-step-n">2</span>
              <div>
                <h3>21 built-in rules</h3>
                <p>
                  Preserve the user's intent, think like a senior engineer, add structure not random
                  length, handle vague requests, protect existing functionality, cover edge cases and
                  acceptance criteria — and never solve the task yourself.
                </p>
              </div>
            </div>
            <div className="sp-step reveal">
              <span className="sp-step-n">3</span>
              <div>
                <h3>Output-only</h3>
                <p>
                  The model returns just the enhanced coding prompt — no commentary, no explanations, no
                  code fences, no "here is your prompt". Instantly copy-pasteable into any AI coding agent.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div className="opt">
          <div className="opt-head">
            <span className="opt-badge badge-free">Go further</span>
            <h2>Write your own</h2>
          </div>
          <p className="opt-sub">
            Every preset is just text — open <b>Settings… → System Prompt</b> and pick{' '}
            <b>Custom</b> to write your own. Define who the model is, what it must always do, what it
            must never do, and the exact output format. That structure is what makes presets reliable.
          </p>
          <div className="cta-local">
            <h2>Put it to work.</h2>
            <p>
              enprompt is free — double-tap ⌥ anywhere and the right writer shows up.
            </p>
            <a href="/#download" className="btn btn-primary">Get enprompt (free)</a>
            <Link to="/learn" className="btn btn-ghost">← All guides</Link>
          </div>
        </div>

      </div>

      <Footer />
    </>
  )
}