import React from 'react';

/**
 * Byværkstederne — EventRow
 * A single calendar/event line: square date block, title + optional time and
 * description, and a meta column on the right (capacity, or an eyebrow+value
 * such as "DROP-IN / Ingen tilmelding"). Colour-coded by workshop via a 4px
 * left border. Nudges right on hover.
 *
 * Responsive by its OWN width (ResizeObserver, not viewport): below ~540px it
 * stacks vertically — the date block goes horizontal (DAY MONTH) and the meta
 * drops below, full width — so it renders cleanly in a narrow column or on a
 * phone alike.
 */
// Reference only — NOT compiled into the design-system bundle.
// In production (Grav/Twig + theme.css) implement this as a CSS container
// query on `.bv-event-row`; see the handoff README. This React version is
// kept for developers who want to see the exact responsive logic.
function EventRow({
  month, day, title, time, description, capacity,
  metaLabel, metaValue, color = 'primary', style, ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [narrow, setNarrow] = React.useState(false);
  const ref = React.useRef(null);

  React.useEffect(() => {
    const el = ref.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver((entries) => {
      setNarrow(entries[0].contentRect.width < 540);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const colors = {
    primary: 'var(--primary)',
    secondary: 'var(--secondary)',
    tertiary: 'var(--tertiary)',
    kulturhus: 'var(--kulturhus)',
  };

  const dateBlock = (
    <div style={{
      fontFamily: 'var(--font-headline)', fontWeight: 700, flexShrink: 0,
      display: 'flex',
      flexDirection: narrow ? 'row' : 'column',
      alignItems: narrow ? 'baseline' : 'center',
      gap: narrow ? 'var(--space-2)' : 0,
      textAlign: 'center',
      minWidth: narrow ? 'auto' : '4rem',
    }}>
      {narrow ? (
        <React.Fragment>
          <span style={{ fontSize: '1.25rem', lineHeight: 1 }}>{day}</span>
          <span style={{ fontSize: '0.8rem', textTransform: 'uppercase', letterSpacing: '0.1em', color: 'var(--on-surface-variant)' }}>{month}</span>
        </React.Fragment>
      ) : (
        <React.Fragment>
          <span style={{ display: 'block', fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.1em', color: 'var(--on-surface-variant)' }}>{month}</span>
          <span style={{ display: 'block', fontSize: '1.5rem', lineHeight: 1 }}>{day}</span>
        </React.Fragment>
      )}
    </div>
  );

  let meta = null;
  if (metaLabel || metaValue) {
    meta = (
      <div style={{
        flexShrink: 0,
        textAlign: narrow ? 'left' : 'right',
        minWidth: narrow ? 'auto' : '7rem',
        width: narrow ? '100%' : undefined,
      }}>
        {metaLabel && (
          <div style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.15em', fontSize: '0.7rem', color: 'var(--on-surface-variant)' }}>{metaLabel}</div>
        )}
        {metaValue && (
          <div style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, fontSize: '0.95rem', marginTop: '0.15rem' }}>{metaValue}</div>
        )}
      </div>
    );
  } else if (capacity) {
    meta = (
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.25rem', color: 'var(--on-surface-variant)', flexShrink: 0, fontSize: '0.875rem', width: narrow ? '100%' : undefined }}>
        <span className="material-symbols-outlined" style={{ fontSize: '1.1rem' }}>group</span>
        {capacity}
      </div>
    );
  }

  return (
    <div
      ref={ref}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: 'flex',
        flexDirection: narrow ? 'column' : 'row',
        alignItems: narrow ? 'flex-start' : 'center',
        gap: narrow ? 'var(--space-3)' : 'var(--space-6)',
        padding: 'var(--space-6) var(--space-4)',
        background: 'var(--surface-container-lowest)',
        borderLeft: `4px solid ${colors[color]}`,
        transform: hover ? 'translateX(0.25rem)' : 'translateX(0)',
        transition: 'transform 0.2s',
        ...style,
      }}
      {...rest}
    >
      {dateBlock}
      <div style={{ flex: narrow ? 'none' : 1, width: narrow ? '100%' : undefined, minWidth: 0 }}>
        <div style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '-0.02em' }}>{title}</div>
        {time && <div style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, fontSize: '0.85rem', marginTop: '0.25rem' }}>{time}</div>}
        {description && <div style={{ fontSize: '0.875rem', color: 'var(--on-surface-variant)', marginTop: '0.25rem' }}>{description}</div>}
      </div>
      {meta}
    </div>
  );
}
