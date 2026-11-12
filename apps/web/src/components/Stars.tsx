/** Five-point star, filled or outlined. Decorative: callers always say the number in text or a label. */
export function StarIcon({ filled }: { filled: boolean }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" className={`star${filled ? " on" : ""}`}>
      <path d="M12 3.2l2.6 5.5 6 .8-4.4 4.1 1.1 5.9L12 16.6l-5.3 2.9 1.1-5.9L3.4 9.5l6-.8z"
            strokeWidth={1.8} strokeLinejoin="round" />
    </svg>
  );
}

/** 1–5 picker as a radio group (arrow keys move, like any radio group). */
export function StarPicker({ value, onChange, disabled }: { value: number; onChange: (n: number) => void; disabled?: boolean }) {
  return (
    <div className="star-picker" role="radiogroup" aria-label="Rating out of 5">
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} type="button" role="radio" aria-checked={value === n} aria-label={`${n} star${n === 1 ? "" : "s"}`}
                disabled={disabled} onClick={() => onChange(n)}
                onKeyDown={(e) => {
                  if (e.key === "ArrowRight" || e.key === "ArrowUp") { e.preventDefault(); onChange(Math.min(5, (value || 0) + 1)); }
                  if (e.key === "ArrowLeft" || e.key === "ArrowDown") { e.preventDefault(); onChange(Math.max(1, (value || 2) - 1)); }
                }}
                tabIndex={value === n || (value === 0 && n === 1) ? 0 : -1}>
          <StarIcon filled={n <= value} />
        </button>
      ))}
    </div>
  );
}

/** Read-only stars with the number for screen readers, e.g. "4.3 out of 5". Rounds to the nearest whole star. */
export function Stars({ value, small }: { value: number; small?: boolean }) {
  const whole = Math.round(value);
  return (
    <span className={`stars${small ? " small" : ""}`} role="img" aria-label={`${value} out of 5`}>
      {[1, 2, 3, 4, 5].map((n) => <StarIcon key={n} filled={n <= whole} />)}
    </span>
  );
}
