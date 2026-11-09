/** 정적 사이트로 내보내기 (Cloudflare Pages 무료 정적 호스팅용, 서버 없음) */
const nextConfig = {
  output: 'export',
  images: { unoptimized: true },
  reactStrictMode: true,
  poweredByHeader: false,
};
export default nextConfig;
