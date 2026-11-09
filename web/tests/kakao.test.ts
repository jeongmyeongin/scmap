import { afterEach, describe, expect, it, vi } from 'vitest';
import { loadErrorMessage, loadKakao, resetKakaoLoaderForTest } from '@/lib/kakao';

afterEach(() => {
  resetKakaoLoaderForTest();
  delete (window as { kakao?: unknown }).kakao;
  document.head.innerHTML = '';
  vi.useRealTimers();
});

describe('카카오 SDK 로더 (실제 SDK 없이 실패 처리만 검사)', () => {
  it('K01 키가 없으면 스크립트를 넣지 않고 no-key 오류', async () => {
    await expect(loadKakao(undefined)).rejects.toEqual({ kind: 'no-key' });
    expect(document.querySelectorAll('script').length).toBe(0);
  });
  it('K02 스크립트 URL: services 라이브러리, autoload=false, 키 인코딩', () => {
    void loadKakao('ab c', 50).catch(() => {});
    const src = document.querySelector('script')!.getAttribute('src')!;
    expect(src.startsWith('https://dapi.kakao.com/v2/maps/sdk.js?')).toBe(true);
    expect(src).toContain('appkey=ab%20c');
    expect(src).toContain('libraries=services');
    expect(src).toContain('autoload=false');
  });
  it('K03 스크립트 로드 실패 → script-failed, 재시도 가능', async () => {
    const p = loadKakao('key', 5000);
    document.querySelector('script')!.dispatchEvent(new Event('error'));
    await expect(p).rejects.toEqual({ kind: 'script-failed' });
    expect(document.querySelectorAll('script').length).toBe(0);
  });
  it('K04 시간 초과 → timeout', async () => {
    vi.useFakeTimers();
    const p = loadKakao('key', 1000);
    vi.advanceTimersByTime(1001);
    await expect(p).rejects.toEqual({ kind: 'timeout' });
  });
  it('K05 스크립트는 받았지만 kakao.maps 없음 → init-failed', async () => {
    const p = loadKakao('key', 5000);
    document.querySelector('script')!.dispatchEvent(new Event('load'));
    await expect(p).rejects.toEqual({ kind: 'init-failed' });
  });
  it('K06 동시에 여러 번 불러도 스크립트는 1개', () => {
    void loadKakao('key', 50).catch(() => {});
    void loadKakao('key', 50).catch(() => {});
    expect(document.querySelectorAll('script').length).toBe(1);
  });
  it('K07 오류마다 사용자가 할 일을 안내', () => {
    for (const kind of ['no-key', 'timeout', 'init-failed', 'script-failed']) {
      expect(loadErrorMessage({ kind }).length).toBeGreaterThan(20);
    }
  });
});
