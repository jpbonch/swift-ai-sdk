'use client';

import type { ReactNode } from 'react';
import type * as PageTree from 'fumadocs-core/page-tree';
import {
  SidebarFolder,
  SidebarFolderContent,
  SidebarFolderLink,
  SidebarFolderTrigger,
} from 'fumadocs-ui/components/sidebar/base';
import { cn } from '@/lib/cn';

// These come from the base sidebar primitives, not the notebook layout's styled
// wrappers, which fumadocs does not export. The base SidebarFolderTrigger
// appends its chevron with `ms-auto`, so without an explicit flex row the arrow
// drops onto its own line under the title.
const row =
  'flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-start ' +
  'text-fd-muted-foreground transition-colors hover:bg-fd-accent ' +
  'hover:text-fd-accent-foreground [&_svg]:size-4 [&_svg]:shrink-0';

export function ZoneAwareFolder({
  item,
  children,
}: {
  item: PageTree.Folder;
  children: ReactNode;
}) {
  if (item.root) return null;

  return (
    <SidebarFolder collapsible={item.collapsible} defaultOpen={item.defaultOpen}>
      {item.index ? (
        <SidebarFolderLink href={item.index.url} className={cn(row)}>
          {item.icon}
          {item.name}
        </SidebarFolderLink>
      ) : (
        <SidebarFolderTrigger className={cn(row)}>
          {item.icon}
          {item.name}
        </SidebarFolderTrigger>
      )}
      <SidebarFolderContent>{children}</SidebarFolderContent>
    </SidebarFolder>
  );
}
