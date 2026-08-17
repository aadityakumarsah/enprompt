import { useEffect } from 'react'
import { Routes, Route, useLocation } from 'react-router-dom'
import Home from './pages/Home'
import RunLocally from './pages/RunLocally'

export default function App() {
  const { pathname } = useLocation()

  // Fresh scroll position on every route change.
  useEffect(() => {
    window.scrollTo(0, 0)
  }, [pathname])

  return (
    <Routes>
      <Route path="/" element={<Home />} />
      <Route path="/run-locally" element={<RunLocally />} />
      {/* Unknown paths render the landing page; Cloudflare Pages rewrites
          all paths to index.html so client-side routing works. */}
      <Route path="*" element={<Home />} />
    </Routes>
  )
}
