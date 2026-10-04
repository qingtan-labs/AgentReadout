import type { Metadata } from 'next';
import './globals.css';

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';

export const metadata: Metadata = {
  title: 'AgentReadout — Codex 与 Claude 额度，一眼读懂',
  description:
    'AgentReadout 是原生 macOS 菜单栏应用，集中展示 Codex 与 Claude 额度、重置时间及每日 Token。',
  applicationName: 'AgentReadout',
  keywords: ['AgentReadout', 'Codex', 'Claude', 'macOS', 'menu bar', 'Tokens', 'quota', 'open source'],
  icons: {
    icon: [
      { url: `${basePath}/favicon.ico?v=3`, sizes: '32x32' },
      { url: `${basePath}/favicon.svg?v=3`, type: 'image/svg+xml' },
      { url: `${basePath}/favicon-32.png?v=3`, sizes: '32x32', type: 'image/png' },
      { url: `${basePath}/favicon-16.png?v=3`, sizes: '16x16', type: 'image/png' },
    ],
    apple: [{ url: `${basePath}/apple-touch-icon.png?v=3`, sizes: '180x180', type: 'image/png' }],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
