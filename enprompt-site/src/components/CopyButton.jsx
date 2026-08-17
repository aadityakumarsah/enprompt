import { useState } from 'react'

/** Button that copies text to the clipboard and flashes "Copied ✓". */
export default function CopyButton({ text, label = 'Copy', className = 'btn btn-black' }) {
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
      } else {
        const ta = document.createElement('textarea')
        ta.value = text
        document.body.appendChild(ta)
        ta.select()
        document.execCommand('copy')
        ta.remove()
      }
    } catch { /* clipboard unavailable - ignore */ }
    setCopied(true)
    setTimeout(() => setCopied(false), 1600)
  }

  return (
    <button type="button" className={className} onClick={copy}>
      {copied ? 'Copied ✓' : label}
    </button>
  )
}
