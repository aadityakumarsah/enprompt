import { useEffect, useRef } from 'react'

/** Floating decorative cubes, generated once on mount (was script.js). */
export default function Cubes() {
  const ref = useRef(null)

  useEffect(() => {
    const layer = ref.current
    if (!layer) return
    const cubes = []
    for (let i = 0; i < 14; i++) {
      const cube = document.createElement('div')
      cube.className = 'cube'
      const size = 14 + Math.random() * 40
      cube.style.setProperty('--s', size + 'px')
      cube.style.left = Math.random() * 100 + '%'
      cube.style.top = Math.random() * 100 + '%'
      cube.style.setProperty('--tx', (Math.random() * 90 - 45).toFixed(0) + 'px')
      cube.style.setProperty('--ty', (Math.random() * 70 - 35).toFixed(0) + 'px')
      cube.style.setProperty('--d', (6 + Math.random() * 9).toFixed(1) + 's')
      cube.style.animationDelay = (Math.random() * 4).toFixed(2) + 's'
      cube.style.opacity = (0.35 + Math.random() * 0.5).toFixed(2)
      layer.appendChild(cube)
      cubes.push(cube)
    }
    return () => cubes.forEach((c) => c.remove())
  }, [])

  return <div id="cubes" ref={ref} className="cubes" aria-hidden="true" />
}
