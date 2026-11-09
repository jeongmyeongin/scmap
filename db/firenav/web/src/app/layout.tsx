import type { Metadata, Viewport } from 'next';
import localFont from 'next/font/local';
import './globals.css';

// Pretendard (SIL Open Font License) — 앱에 포함해 기기마다 같은 글꼴로 표시
const pretendard = localFont({
  src: '../../node_modules/pretendard/dist/web/variable/woff2/PretendardVariable.woff2',
  weight: '45 920',
  display: 'swap',
  variable: '--font-sans',
});

export const metadata: Metadata = {
  title: '소방차 안전경로',
  description: '소방차량 제원별 통행 위험 구간 안내 (참고용)',
  manifest: '/manifest.webmanifest',
  icons: { icon: '/icon.svg' },
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#B3121F' },
    { media: '(prefers-color-scheme: dark)', color: '#15181C' },
  ],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ko" className={pretendard.variable}>
      <body>{children}</body>
    </html>
  );
}
