import { useEffect } from 'react'
import { Link, useLocation } from 'react-router-dom'

/** Top navigation with the blur-on-scroll behavior (was script.js).
 *  Internal links use react-router so no page reload happens. */
export default function Nav({ ctaLabel = 'Get enprompt' }) {
  const { pathname } = useLocation()

  useEffect(() => {
    const nav = document.querySelector('.nav')
    if (!nav) return
    const onScroll = () => {
      nav.style.background =
        window.scrollY > 12
          ? 'rgba(253, 250, 246, 0.92)'
          : 'rgba(253, 250, 246, 0.75)'
    }
    onScroll()
    window.addEventListener('scroll', onScroll)
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  const localActive = pathname.startsWith('/run-locally')
  const learnActive = pathname.startsWith('/learn')

  return (
    <nav className="nav">
      <div className="nav-inner">
        <Link to="/" className="brand">
          <img src="/assets/icon.png" alt="enprompt" className="brand-icon" />
          <span className="brand-name">enprompt</span>
        </Link>
        <div className="nav-links">
          <a href="/#features">Features</a>
          <a href="/#download">Install</a>
          <a href="/#how">Shortcuts</a>
          <a href="/#setup">FAQ</a>
          <Link to="/run-locally" style={localActive ? { color: 'var(--accent-deep)', fontWeight: 600 } : undefined}>
            Run locally
          </Link>
          <Link to="/learn" style={learnActive ? { color: 'var(--accent-deep)', fontWeight: 600 } : undefined}>
            Learn
          </Link>
        </div>
        <div className="nav-actions">
          <a
            href="https://github.com/aadityakumarsah/enprompt"
            target="_blank"
            rel="noopener"
            className="nav-github"
            aria-label="enprompt on GitHub"
            title="enprompt on GitHub"
          >
            <svg viewBox="0 0 16 16" width="20" height="20" fill="currentColor" aria-hidden="true">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
            </svg>
          </a>
          <a href="/#download" className="btn btn-black nav-cta">{ctaLabel}</a>
        </div>
      </div>
    </nav>
  )
}
