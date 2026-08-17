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
          <a href="https://github.com/aadityakumarsah/enprompt" target="_blank" rel="noopener">GitHub</a>
        </div>
        <a href="/#download" className="btn btn-black nav-cta">{ctaLabel}</a>
      </div>
    </nav>
  )
}
