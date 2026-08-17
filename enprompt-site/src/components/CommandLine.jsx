import CopyButton from './CopyButton'

/** Terminal-style command line with a copy button and optional hint text. */
export default function CommandLine({ id, text, hint }) {
  return (
    <div>
      <div className="cmd">
        <code id={id}>{text}</code>
        <CopyButton text={text} />
      </div>
      {hint && <p className="cmd-hint">{hint}</p>}
    </div>
  )
}
