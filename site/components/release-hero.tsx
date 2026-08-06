import { SwiftBird } from '@/components/logo';

/**
 * The card that opens a release entry. Same language as the OG images and the
 * launch posts — Swift-orange halftone over near-black, brand mark, one accent
 * word — so a release reads the same wherever someone meets it.
 */
export function ReleaseHero({
  version,
  kicker,
  title,
  accent,
  children,
}: {
  version: string;
  kicker: string;
  title: string;
  accent?: string;
  children?: React.ReactNode;
}) {
  return (
    <div className="not-prose relative my-8 overflow-hidden rounded-xl border border-fd-border bg-[#0a0a0a]">
      {/* The halftone is a background layer, so it never sits over the text. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          backgroundImage:
            'radial-gradient(circle at 1.5px 1.5px, var(--color-fd-primary) 1.5px, transparent 0)',
          backgroundSize: '14px 14px',
          maskImage:
            'radial-gradient(ellipse 90% 100% at 20% 0%, black 0%, rgba(0,0,0,0.25) 55%, transparent 100%)',
          WebkitMaskImage:
            'radial-gradient(ellipse 90% 100% at 20% 0%, black 0%, rgba(0,0,0,0.25) 55%, transparent 100%)',
          opacity: 0.4,
        }}
      />
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            'radial-gradient(ellipse 70% 80% at 18% 0%, color-mix(in oklab, var(--color-fd-primary) 20%, transparent), transparent 70%)',
        }}
      />

      <div className="relative flex flex-col gap-5 p-7 sm:p-9">
        <div className="flex items-center gap-2.5">
          <SwiftBird className="size-6 text-[var(--color-fd-primary)]" />
          <span className="text-base font-semibold tracking-[0.01em] text-white">AI SDK</span>
          <span className="ml-auto font-mono text-sm text-neutral-400">{version}</span>
        </div>

        <div className="flex flex-col gap-3">
          <span className="text-xs font-bold uppercase tracking-[0.18em] text-[var(--color-fd-primary)]">
            {kicker}
          </span>
          <h3 className="text-3xl font-semibold leading-tight tracking-[-0.02em] text-white sm:text-[2.6rem]">
            {title}
            {accent ? (
              <span className="text-[var(--color-fd-primary)]"> {accent}</span>
            ) : null}
          </h3>
          {children ? (
            <div className="max-w-2xl text-[0.98rem] leading-relaxed text-neutral-400">
              {children}
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
