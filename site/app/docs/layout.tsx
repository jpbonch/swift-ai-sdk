import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/notebook';
import { buttonVariants } from 'fumadocs-ui/components/ui/button';
import { RiSparklingLine } from '@remixicon/react';
import { baseOptions } from '@/lib/layout.shared';
import { cn } from '@/lib/cn';
import { DocsBackdrop } from '@/components/shader-art';
import { ZoneAwareFolder } from '@/components/sidebar-folder';
import { AISearch, AISearchPanel, AISearchTrigger } from '@/components/ai/search';

export default function Layout({ children }: LayoutProps<'/docs'>) {
  const base = baseOptions();

  const pages = source.getPages();
  const isGuide = (url: string) => url.startsWith('/docs/guides');
  const isProvider = (url: string) => url.startsWith('/docs/providers');
  const isChangelog = (url: string) => url.startsWith('/docs/changelog');
  const isReference = (url: string) => url.startsWith('/docs/reference');
  const isTroubleshooting = (url: string) => url.startsWith('/docs/troubleshooting');
  const inOwnTab = (url: string) =>
    isGuide(url) || isProvider(url) || isChangelog(url) || isReference(url) || isTroubleshooting(url);

  const tabs = [
    {
      title: 'Documentation',
      description: 'The library, end to end.',
      url: '/docs',
      urls: new Set(pages.filter((page) => !inOwnTab(page.url)).map((page) => page.url)),
    },
    {
      title: 'Reference',
      description: 'Every public function, signature by signature.',
      url: '/docs/reference',
      urls: new Set(pages.filter((page) => isReference(page.url)).map((page) => page.url)),
    },
    {
      title: 'Troubleshooting',
      description: 'Specific symptoms and what to change.',
      url: '/docs/troubleshooting',
      urls: new Set(pages.filter((page) => isTroubleshooting(page.url)).map((page) => page.url)),
    },
    {
      title: 'Providers',
      description: 'Every pack, its setup, features, and models.',
      url: '/docs/providers',
      urls: new Set(pages.filter((page) => isProvider(page.url)).map((page) => page.url)),
    },
    {
      title: 'Guides',
      description: 'Build something real, step by step.',
      url: '/docs/guides',
      urls: new Set(pages.filter((page) => isGuide(page.url)).map((page) => page.url)),
    },
    {
      title: 'Changelog',
      description: 'What shipped in each release.',
      url: '/docs/changelog',
      urls: new Set(pages.filter((page) => isChangelog(page.url)).map((page) => page.url)),
    },
  ];

  return (
    <div className="relative">
      <DocsBackdrop />
      <DocsLayout
        tree={source.getPageTree()}
        {...base}
        nav={{ ...base.nav, mode: 'top' }}
        tabMode="navbar"
        tabs={tabs}
        sidebar={{ components: { Folder: ZoneAwareFolder } }}
      >
        <AISearch>
          <AISearchPanel />
          <AISearchTrigger
            position="float"
            className={cn(
              buttonVariants({
                variant: 'secondary',
                className: 'card-surface gap-2 rounded-full text-fd-muted-foreground',
              }),
            )}
          >
            <RiSparklingLine className="size-4 text-[oklch(0.65_0.199_31.6)]" />
            Ask AI
          </AISearchTrigger>
        </AISearch>
        {children}
      </DocsLayout>
    </div>
  );
}
