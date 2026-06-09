import React from 'react';

/**
 * Byværkstederne — EventRow (REV 2 reference)
 * A single calendar/event line for /vaerkstedskalenderen. Three columns —
 * DATE | BODY | META.
 *
 *   • DATE  — square month-over-day block (goes horizontal "DAY MONTH" stacked).
 *   • BODY  — optional badge eyebrow, the title as a semantic <h3>, optional
 *             bold time line, optional one-line description.
 *   • META  — up to three stacked, independently-optional slots: a prominent
 *             PRICE eyebrow, a CTA button (label + href), and a read-only
 *             CAPACITY counter ("12 / 20") with a group icon. Empty slots
 *             collapse; any combination renders simultaneously.
 *
 * `color` is the VISUAL left-border hue (presentation only). `filter` is the
 * FILTER ID, emitted as `data-group` for the calendar's filter buttons —
 * behaviour only. Keep them distinct (this was reviewer blocker F1).
 *
 * Responsive by its OWN width (ResizeObserver here; a CSS container query in
 * production — see README). Below ~540px it stacks: date goes horizontal,
 * body + meta go full width, and the CTA stretches to a full-width tap target.
 */
// Reference only — NOT compiled into the design-system bundle. In production
// (Grav/Twig + theme.css) implement this as a CSS container query on a
// per-row WRAPPER (.bv-event-item), not on .bv-event-row itself — an element
// cannot react to its own container-type. See the handoff README.
function EventRow({
  month, day,
  badge, badgeVariant,
  title, time, description,
  price, ctaLabel, ctaHref, ctaVariant = 'secondary', capacity,
  color = 'primary', filter,
  style, ...rest
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
  const accent = colors[color] || colors.primary;

  const badgeFill = {
    primary: { background: 'var(--primary)', color: 'var(--on-primary)' },
    secondary: { background: 'var(--secondary)', color: 'var(--on-secondary)' },
    tertiary: { background: 'var(--tertiary)', color: 'var(--on-tertiary)' },
    kulturhus: { background: 'var(--kulturhus)', color: '#fff' },
  }[badgeVariant || color] || { background: 'var(--primary)', color: 'var(--on-primary)' };

  const ctaFill = {
    primary: { background: 'var(--primary)', color: 'var(--on-primary)' },
    secondary: { background: 'var(--secondary-container)', color: 'var(--on-secondary-container)' },
    tertiary: { background: 'var(--tertiary)', color: 'var(--on-tertiary)' },
    dark: { background: 'var(--inverse-surface)', color: 'var(--inverse-on-surface)' },
  }[ctaVariant] || { background: 'var(--secondary-container)', color: 'var(--on-secondary-container)' };

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

  const hasMeta = price || (ctaLabel && ctaHref) || capacity;
  const meta = hasMeta ? (
    <div style={{
      flexShrink: 0, display: 'flex', flexDirection: 'column',
      alignItems: narrow ? 'flex-start' : 'flex-end',
      gap: 'var(--space-2)', textAlign: narrow ? 'left' : 'right',
      minWidth: narrow ? 'auto' : '9rem',
      width: narrow ? '100%' : undefined,
      marginTop: narrow ? 'var(--space-2)' : undefined,
    }}>
      {price && (
        <span style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, fontSize: '0.95rem', lineHeight: 1.2 }}>{price}</span>
      )}
      {ctaLabel && ctaHref && (
        <a href={ctaHref} style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          fontFamily: 'var(--font-headline)', fontWeight: 700, textTransform: 'uppercase',
          letterSpacing: 'var(--tracking-button)', fontSize: '0.875rem', lineHeight: 1,
          padding: 'var(--space-2) var(--space-6)', borderRadius: 0, textDecoration: 'none',
          width: narrow ? '100%' : undefined, ...ctaFill,
        }}>{ctaLabel}</a>
      )}
      {capacity && (
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.25rem', color: 'var(--on-surface-variant)', fontSize: '0.875rem' }}>
          <span className="material-symbols-outlined" style={{ fontSize: '1.1rem' }}>group</span>
          {capacity}
        </span>
      )}
    </div>
  ) : null;

  return (
    <div
      ref={ref}
      data-group={filter}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: 'flex',
        flexDirection: narrow ? 'column' : 'row',
        alignItems: narrow ? 'flex-start' : 'center',
        gap: narrow ? 'var(--space-3)' : 'var(--space-6)',
        padding: 'var(--space-6) var(--space-4)',
        background: 'var(--surface-container-lowest)',
        borderLeft: `4px solid ${accent}`,
        transform: hover ? 'translateX(0.25rem)' : 'translateX(0)',
        transition: 'transform 0.2s',
        ...style,
      }}
      {...rest}
    >
      {dateBlock}
      <div style={{
        flex: narrow ? 'none' : 1, width: narrow ? '100%' : undefined, minWidth: 0,
        display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 'var(--space-1)',
      }}>
        {badge && (
          <span style={{
            display: 'inline-block', fontFamily: 'var(--font-headline)', fontWeight: 700,
            textTransform: 'uppercase', letterSpacing: 'var(--tracking-label)', fontSize: 'var(--text-label)',
            lineHeight: 1.4, padding: '0.25rem 0.75rem', whiteSpace: 'nowrap', marginBottom: 'var(--space-1)',
            ...badgeFill,
          }}>{badge}</span>
        )}
        <h3 style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '-0.02em', fontSize: '1.25rem', lineHeight: 1.15, margin: 0 }}>{title}</h3>
        {time && <div style={{ fontFamily: 'var(--font-headline)', fontWeight: 700, fontSize: '0.85rem' }}>{time}</div>}
        {description && <div style={{ fontFamily: 'var(--font-body)', fontSize: '0.875rem', color: 'var(--on-surface-variant)', textWrap: 'pretty' }}>{description}</div>}
      </div>
      {meta}
    </div>
  );
}
