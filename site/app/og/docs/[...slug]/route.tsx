import { getPageImage, source } from '@/lib/source';
import { notFound } from 'next/navigation';
import { ImageResponse } from 'next/og';
import { appName } from '@/lib/shared';

export const revalidate = false;

const WIDTH = 1200;
const HEIGHT = 630;

const BACKGROUND = '#0a0a0a';
const FOREGROUND = '#fafafa';
const MUTED = '#a1a1a1';
const SWIFT_ORANGE = '#f05138';

/**
 * The site's backdrop is a WebGL dithering shader, which satori can't run.
 * This is the same idea in static form: a Swift-orange halftone grid faded out
 * from the top-left, over a warm glow.
 */
const backdrop = `
<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}">
  <defs>
    <pattern id="dots" width="14" height="14" patternUnits="userSpaceOnUse">
      <circle cx="2" cy="2" r="1.6" fill="${SWIFT_ORANGE}" />
    </pattern>
    <radialGradient id="fade" cx="0.28" cy="0" r="0.9">
      <stop offset="0%" stop-color="#fff" stop-opacity="0.42" />
      <stop offset="55%" stop-color="#fff" stop-opacity="0.10" />
      <stop offset="100%" stop-color="#fff" stop-opacity="0" />
    </radialGradient>
    <radialGradient id="glow" cx="0.22" cy="0" r="0.75">
      <stop offset="0%" stop-color="${SWIFT_ORANGE}" stop-opacity="0.20" />
      <stop offset="100%" stop-color="${SWIFT_ORANGE}" stop-opacity="0" />
    </radialGradient>
    <mask id="softEdge">
      <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#fade)" />
    </mask>
  </defs>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#glow)" />
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#dots)" mask="url(#softEdge)" />
</svg>`;

const swiftBirdPath =
  'M13.543 3.41c4.114 2.47 6.545 7.162 5.549 11.131-.024.093-.05.181-.076.272l.002.001c2.062 2.538 1.5 5.258 1.236 4.745-1.072-2.086-3.066-1.568-4.088-1.043a6.803 6.803 0 0 1-.281.158l-.02.012-.002.002c-2.115 1.123-4.957 1.205-7.812-.022a12.568 12.568 0 0 1-5.64-4.838c.649.48 1.35.902 2.097 1.252 3.019 1.414 6.051 1.311 8.197-.002C9.651 12.73 7.101 9.67 5.146 7.191a10.628 10.628 0 0 1-1.005-1.384c2.34 2.142 6.038 4.83 7.365 5.576C8.69 8.408 6.208 4.743 6.324 4.86c4.436 4.47 8.528 6.996 8.528 6.996.154.085.27.154.36.213.085-.215.16-.437.224-.668.708-2.588-.09-5.548-1.893-7.992z';

const bird = `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="52" height="52">
  <path d="${swiftBirdPath}" transform="translate(24 0) scale(-1 1)" fill="none"
    stroke="${FOREGROUND}" stroke-width="1.2" stroke-linejoin="round" stroke-linecap="round" />
</svg>`;

const dataURI = (svg: string) =>
  `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;

/** Which part of the docs a page belongs to, for the label above the title. */
function sectionFor(slug: string[]): string {
  const labels: Record<string, string> = {
    reference: 'API reference',
    troubleshooting: 'Troubleshooting',
    providers: 'Providers',
    guides: 'Guides',
    foundations: 'Foundations',
    changelog: 'Changelog',
  };
  return (slug[0] && labels[slug[0]]) || 'Documentation';
}

/**
 * Google Sans Flex, the same face the site uses. Google serves it as TTF, which
 * satori can read directly. Fetched once per build rather than per page, and
 * the render falls back to the bundled font if the network is unavailable.
 */
let fontsPromise: Promise<{ name: string; data: ArrayBuffer; weight: 400 | 600 }[] | undefined>;

function loadFonts() {
  fontsPromise ??= (async () => {
    try {
      const css = await fetch(
        'https://fonts.googleapis.com/css2?family=Google+Sans+Flex:wght@400;600&display=swap',
        { headers: { 'User-Agent': 'Mozilla/5.0' } },
      ).then((res) => res.text());

      const urls = [...css.matchAll(/src:\s*url\((https:[^)]+\.ttf)\)/g)].map((m) => m[1]!);
      if (urls.length < 2) return undefined;

      const [regular, semibold] = await Promise.all(
        urls.slice(0, 2).map((url) => fetch(url).then((res) => res.arrayBuffer())),
      );

      return [
        { name: 'Google Sans Flex', data: regular!, weight: 400 as const },
        { name: 'Google Sans Flex', data: semibold!, weight: 600 as const },
      ];
    } catch {
      return undefined;
    }
  })();

  return fontsPromise;
}

export async function GET(_req: Request, { params }: RouteContext<'/og/docs/[...slug]'>) {
  const { slug } = await params;
  const page = source.getPage(slug.slice(0, -1));
  if (!page) notFound();

  const title = page.data.title;
  const description = page.data.description;
  const fonts = await loadFonts();

  // Long symbol names (lastAssistantMessageIsCompleteWithApprovalResponses) are
  // one unbroken word, so they need both a smaller size and explicit breaking.
  const titleSize = title.length > 44 ? 52 : title.length > 30 ? 66 : 84;

  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          background: BACKGROUND,
          padding: '64px 72px',
          fontFamily: 'Google Sans Flex',
          position: 'relative',
        }}
      >
        <img
          src={dataURI(backdrop)}
          width={WIDTH}
          height={HEIGHT}
          style={{ position: 'absolute', top: 0, left: 0 }}
        />

        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <img src={dataURI(bird)} width={52} height={52} />
          <span
            style={{
              fontSize: 34,
              fontWeight: 600,
              color: FOREGROUND,
              letterSpacing: '0.03em',
            }}
          >
            AI SDK
          </span>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column' }}>
          <span
            style={{
              fontSize: 24,
              fontWeight: 600,
              color: SWIFT_ORANGE,
              letterSpacing: '0.12em',
              textTransform: 'uppercase',
              marginBottom: 20,
            }}
          >
            {sectionFor(slug)}
          </span>
          <span
            style={{
              fontSize: titleSize,
              fontWeight: 600,
              color: FOREGROUND,
              lineHeight: 1.1,
              letterSpacing: '-0.02em',
              wordBreak: 'break-word',
              display: '-webkit-box',
              WebkitBoxOrient: 'vertical',
              WebkitLineClamp: 2,
              overflow: 'hidden',
            }}
          >
            {title}
          </span>
          {description ? (
            <span
              style={{
                fontSize: 30,
                color: MUTED,
                lineHeight: 1.4,
                marginTop: 22,
                // Two lines of description, then cut.
                display: '-webkit-box',
                WebkitBoxOrient: 'vertical',
                WebkitLineClamp: 2,
                overflow: 'hidden',
              }}
            >
              {description}
            </span>
          ) : null}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 18 }}>
          <div style={{ display: 'flex', width: 56, height: 3, background: SWIFT_ORANGE }} />
          <span style={{ fontSize: 24, color: MUTED }}>{appName}</span>
        </div>
      </div>
    ),
    { width: WIDTH, height: HEIGHT, fonts },
  );
}

export function generateStaticParams() {
  return source.getPages().map((page) => ({
    lang: page.locale,
    slug: getPageImage(page).segments,
  }));
}
