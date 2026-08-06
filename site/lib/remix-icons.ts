import { createElement, type ComponentType, type ReactElement } from 'react';
import {
  RiBookOpenLine,
  RiBracesLine,
  RiBrainLine,
  RiBubbleChartLine,
  RiChat3Line,
  RiCompass3Line,
  RiCpuLine,
  RiFlaskLine,
  RiBroadcastLine,
  RiRefreshLine,
  RiGalleryLine,
  RiHistoryLine,
  RiImageLine,
  RiPlugLine,
  RiPulseLine,
  RiRoadMapLine,
  RiRobot2Line,
  RiRocketLine,
  RiSettings3Line,
  RiSparklingLine,
  RiTableLine,
  RiText,
  RiToolsLine,
  RiVoiceprintLine,
} from '@remixicon/react';
import { HugeiconsIcon, type IconSvgElement } from '@hugeicons/react';
import {
  Activity03Icon,
  Alert02Icon,
  ComputerTerminal01Icon,
  DatabaseIcon,
  Files01Icon,
  Layers01Icon,
  MessageMultiple01Icon,
  Mic01Icon,
  Scissor01Icon,
  SortingAZ01Icon,
  SubtitleIcon,
  Timer02Icon,
  Video01Icon,
  VolumeHighIcon,
} from '@hugeicons/core-free-icons';

const remix: Record<string, ComponentType> = {
  AudioWaveform: RiVoiceprintLine,
  BookOpen: RiBookOpenLine,
  Bot: RiRobot2Line,
  Braces: RiBracesLine,
  Brain: RiBrainLine,
  Cable: RiPlugLine,
  Compass: RiCompass3Line,
  Cpu: RiCpuLine,
  Radio: RiBroadcastLine,
  RefreshCw: RiRefreshLine,
  FlaskConical: RiFlaskLine,
  History: RiHistoryLine,
  Image: RiImageLine,
  Images: RiGalleryLine,
  Map: RiRoadMapLine,
  MessageSquare: RiChat3Line,
  Network: RiBubbleChartLine,
  Rocket: RiRocketLine,
  Settings: RiSettings3Line,
  Sparkles: RiSparklingLine,
  Table: RiTableLine,
  Type: RiText,
  Waves: RiPulseLine,
  Wrench: RiToolsLine,
};

const huge: Record<string, IconSvgElement> = {
  Activity: Activity03Icon,
  Files: Files01Icon,
  Layers: Layers01Icon,
  Messages: MessageMultiple01Icon,
  Mic: Mic01Icon,
  Scissors: Scissor01Icon,
  Sort: SortingAZ01Icon,
  Subtitle: SubtitleIcon,
  Terminal: ComputerTerminal01Icon,
  Timer: Timer02Icon,
  TriangleAlert: Alert02Icon,
  Variable: DatabaseIcon,
  Video: Video01Icon,
  Volume: VolumeHighIcon,
};

function resolve(name: string): ReactElement | undefined {
  const Remix = remix[name];
  if (Remix) return createElement(Remix);

  const icon = huge[name];
  if (icon) return createElement(HugeiconsIcon, { icon, strokeWidth: 1.8 });

  return undefined;
}

function replaceIcon<T extends { icon?: unknown }>(node: T): T {
  if (typeof node.icon === 'string') {
    const element = resolve(node.icon);
    if (!element) console.warn(`[icons] Unknown icon: ${node.icon}`);
    node.icon = element;
  }
  return node;
}

export function remixIconsPlugin() {
  return {
    name: 'docs:icon',
    transformPageTree: {
      file: replaceIcon,
      folder: replaceIcon,
      separator: replaceIcon,
    },
  };
}
