'use client';

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createKakaoBackend, loadErrorMessage, loadKakao, type Kakao } from '@/lib/kakao';
import { SearchService, type Place, type SearchMode, type SearchOutcome } from '@/lib/search';
import { DEFAULT_CENTER, distanceMeters, formatLatLng, isInKorea, type LatLng } from '@/lib/geo';
import { readTodayCalls, recordCall } from '@/lib/usage';

type Endpoint = { label: string; position: LatLng; source: 'gps' | 'search' | 'map' } | null;
type GpsState =
  | { kind: 'idle' }
  | { kind: 'locating' }
  | { kind: 'ok'; position: LatLng; accuracy: number; at: number }
  | { kind: 'error'; message: string };

const KAKAO_KEY = process.env.NEXT_PUBLIC_KAKAO_JS_KEY;

function gpsErrorMessage(err: GeolocationPositionError | { code: number }): string {
  switch (err.code) {
    case 1:
      return '위치 권한이 거부되었습니다. 브라우저 설정에서 이 사이트의 위치 권한을 허용하세요.';
    case 2:
      return '현재 위치를 확인할 수 없습니다. GPS가 켜져 있는지 확인하세요.';
    case 3:
      return '위치 확인 시간이 초과되었습니다. 하늘이 보이는 곳에서 다시 시도하세요.';
    default:
      return '이 브라우저는 위치 기능을 지원하지 않습니다.';
  }
}

function outcomeMessage(o: SearchOutcome | null): string | null {
  if (!o) return null;
  switch (o.kind) {
    case 'invalid':
      return o.message;
    case 'empty':
      return '검색 결과가 없습니다. 도로명·지번 주소 또는 장소명 탭을 바꿔 다시 검색하세요.';
    case 'throttled':
      return `너무 빠르게 검색했습니다. ${Math.ceil(o.retryInMs / 1000)}초 뒤에 다시 검색하세요.`;
    case 'error':
      return o.message;
    case 'paused':
      return null; // 별도 안내 영역에서 표시
    case 'results':
      return o.droppedOutsideKorea > 0 ? `국내 범위를 벗어난 좌표 ${o.droppedOutsideKorea}건은 제외했습니다.` : null;
  }
}

export default function NavApp() {
  const mapEl = useRef<HTMLDivElement>(null);
  const kakaoRef = useRef<Kakao>(null);
  const mapRef = useRef<Kakao>(null);
  const overlays = useRef<{ gps?: Kakao; acc?: Kakao; origin?: Kakao; dest?: Kakao; results: Kakao[] }>({ results: [] });

  const [mapState, setMapState] = useState<'loading' | 'ready' | 'failed'>('loading');
  const [mapError, setMapError] = useState<string>('');
  const [gps, setGps] = useState<GpsState>({ kind: 'idle' });
  const [origin, setOrigin] = useState<Endpoint>(null);
  const [dest, setDest] = useState<Endpoint>(null);
  const [pickMode, setPickMode] = useState(false);
  const [mode, setMode] = useState<SearchMode>('address');
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<SearchOutcome | null>(null);
  const [results, setResults] = useState<Place[]>([]);
  const [calls, setCalls] = useState(0);
  const [pausedUntil, setPausedUntil] = useState<number | null>(null);
  const [panelOpen, setPanelOpen] = useState(true);
  const serviceRef = useRef<SearchService | null>(null);

  useEffect(() => setCalls(readTodayCalls()), []);

  // ---------- 지도 불러오기 ----------
  useEffect(() => {
    let cancelled = false;
    loadKakao(KAKAO_KEY)
      .then((k) => {
        if (cancelled || !mapEl.current) return;
        kakaoRef.current = k;
        mapRef.current = new k.maps.Map(mapEl.current, {
          center: new k.maps.LatLng(DEFAULT_CENTER.lat, DEFAULT_CENTER.lng),
          level: 5,
        });
        serviceRef.current = new SearchService(createKakaoBackend(k), {
          onApiCall: () => setCalls(recordCall()),
        });
        setMapState('ready');
      })
      .catch((e) => {
        if (cancelled) return;
        setMapError(loadErrorMessage(e));
        setMapState('failed');
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // ---------- 현재 위치 ----------
  const locate = useCallback(() => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      setGps({ kind: 'error', message: gpsErrorMessage({ code: 0 }) });
      return;
    }
    setGps({ kind: 'locating' });
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const p = { lat: pos.coords.latitude, lng: pos.coords.longitude };
        if (!isInKorea(p)) {
          setGps({ kind: 'error', message: '확인된 위치가 국내 범위를 벗어났습니다. 위치 설정을 확인하세요.' });
          return;
        }
        setGps({ kind: 'ok', position: p, accuracy: pos.coords.accuracy, at: Date.now() });
      },
      (err) => setGps({ kind: 'error', message: gpsErrorMessage(err) }),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 10000 },
    );
  }, []);

  useEffect(() => {
    if (mapState === 'ready') locate();
  }, [mapState, locate]);

  // 출발지 기본값 = 현재 위치 (검색 호출을 줄이기 위함)
  useEffect(() => {
    if (gps.kind === 'ok' && (!origin || origin.source === 'gps')) {
      setOrigin({ label: '현재 위치', position: gps.position, source: 'gps' });
    }
  }, [gps, origin]);

  // ---------- 지도 위 표시 ----------
  const pin = useCallback((p: LatLng, cls: string, text: string) => {
    const k = kakaoRef.current;
    const el = document.createElement('div');
    el.className = `pin ${cls}`;
    el.textContent = text;
    return new k.maps.CustomOverlay({ position: new k.maps.LatLng(p.lat, p.lng), content: el, yAnchor: 1, zIndex: 3 });
  }, []);

  useEffect(() => {
    const k = kakaoRef.current;
    const map = mapRef.current;
    if (!k || !map) return;
    overlays.current.gps?.setMap(null);
    overlays.current.acc?.setMap(null);
    if (gps.kind === 'ok') {
      const el = document.createElement('div');
      el.className = 'gps-dot';
      el.setAttribute('aria-label', '현재 위치');
      overlays.current.gps = new k.maps.CustomOverlay({
        position: new k.maps.LatLng(gps.position.lat, gps.position.lng),
        content: el,
        zIndex: 4,
      });
      overlays.current.acc = new k.maps.Circle({
        center: new k.maps.LatLng(gps.position.lat, gps.position.lng),
        radius: Math.min(gps.accuracy, 2000),
        strokeWeight: 1,
        strokeColor: '#1F5FBF',
        strokeOpacity: 0.6,
        fillColor: '#1F5FBF',
        fillOpacity: 0.12,
      });
      overlays.current.gps.setMap(map);
      overlays.current.acc.setMap(map);
      map.panTo(new k.maps.LatLng(gps.position.lat, gps.position.lng));
    }
  }, [gps, mapState]);

  useEffect(() => {
    const k = kakaoRef.current;
    const map = mapRef.current;
    if (!k || !map) return;
    overlays.current.origin?.setMap(null);
    overlays.current.dest?.setMap(null);
    overlays.current.origin = undefined;
    overlays.current.dest = undefined;
    if (origin && origin.source !== 'gps') {
      overlays.current.origin = pin(origin.position, 'pin-origin', '출발');
      overlays.current.origin.setMap(map);
    }
    if (dest) {
      overlays.current.dest = pin(dest.position, 'pin-dest', '도착');
      overlays.current.dest.setMap(map);
    }
    if (origin && dest) {
      const b = new k.maps.LatLngBounds();
      b.extend(new k.maps.LatLng(origin.position.lat, origin.position.lng));
      b.extend(new k.maps.LatLng(dest.position.lat, dest.position.lng));
      map.setBounds(b, 80, 80, 80, 80);
    } else if (dest) {
      map.panTo(new k.maps.LatLng(dest.position.lat, dest.position.lng));
    }
  }, [origin, dest, pin, mapState]);

  useEffect(() => {
    const k = kakaoRef.current;
    const map = mapRef.current;
    if (!k || !map) return;
    overlays.current.results.forEach((o) => o.setMap(null));
    overlays.current.results = results.slice(0, 15).map((r, i) => {
      const o = pin(r.position, 'pin-result', String(i + 1));
      o.setMap(map);
      return o;
    });
  }, [results, pin]);

  // 지도에서 목적지 선택 (실수 방지를 위해 선택 모드에서만)
  useEffect(() => {
    const k = kakaoRef.current;
    const map = mapRef.current;
    if (!k || !map || !pickMode) return;
    const handler = (e: Kakao) => {
      const p = { lat: e.latLng.getLat(), lng: e.latLng.getLng() };
      if (!isInKorea(p)) return;
      setDest({ label: `지도에서 선택한 지점 (${formatLatLng(p)})`, position: p, source: 'map' });
      setPickMode(false);
    };
    k.maps.event.addListener(map, 'click', handler);
    return () => k.maps.event.removeListener(map, 'click', handler);
  }, [pickMode, mapState]);

  // ---------- 검색 ----------
  const runSearch = useCallback(async () => {
    const svc = serviceRef.current;
    if (!svc || busy) return;
    setBusy(true);
    const map = mapRef.current;
    const near = map ? { lat: map.getCenter().getLat(), lng: map.getCenter().getLng() } : null;
    const o = await svc.search(mode, query, near);
    setOutcome(o);
    setPausedUntil(svc.pausedUntilTime());
    if (o.kind === 'results') setResults(o.places);
    else if (o.kind === 'empty') setResults([]);
    setBusy(false);
  }, [mode, query, busy]);

  const choose = (p: Place, as: 'origin' | 'dest') => {
    const ep = { label: p.name, position: p.position, source: 'search' as const };
    if (as === 'origin') setOrigin(ep);
    else setDest(ep);
    setResults([]);
    setOutcome(null);
    if (typeof window !== 'undefined' && window.matchMedia('(max-width: 759px)').matches) setPanelOpen(false);
  };

  const straight = useMemo(
    () => (origin && dest ? distanceMeters(origin.position, dest.position) : null),
    [origin, dest],
  );
  const msg = outcomeMessage(outcome);
  const searchDisabled = mapState !== 'ready' || pausedUntil !== null;

  return (
    <div className="app">
      <section className={`panel ${panelOpen ? 'is-open' : 'is-closed'}`} aria-label="출발지와 목적지 설정">
        <div className="chevron" aria-hidden="true" />
        <header className="panel-head">
          <h1>소방차 안전경로</h1>
          <button type="button" className="panel-toggle" onClick={() => setPanelOpen((v) => !v)} aria-expanded={panelOpen}>
            {panelOpen ? '지도 넓게 보기' : '검색 열기'}
          </button>
        </header>

        <p className="notice" role="note">
          참고용 안내입니다. 현장 상황과 지휘 판단이 우선합니다.
        </p>

        <div className="panel-body">
          <dl className="endpoints">
            <div className="endpoint">
              <dt>출발</dt>
              <dd>
                {origin ? origin.label : gps.kind === 'locating' ? '현재 위치 확인 중' : '지정되지 않음'}
                {origin && origin.source !== 'gps' && (
                  <button type="button" className="link" onClick={() => setOrigin(gps.kind === 'ok' ? { label: '현재 위치', position: gps.position, source: 'gps' } : null)}>
                    현재 위치로 되돌리기
                  </button>
                )}
              </dd>
            </div>
            <div className="endpoint">
              <dt>도착</dt>
              <dd>
                {dest ? dest.label : '아래에서 검색하거나 지도에서 선택하세요'}
                {dest && (
                  <button type="button" className="link" onClick={() => setDest(null)}>
                    지우기
                  </button>
                )}
              </dd>
            </div>
          </dl>

          {origin && dest && (
            <div className="route-pending" role="status">
              <p>
                직선거리 {straight! >= 1000 ? `${(straight! / 1000).toFixed(1)}km` : `${Math.round(straight!)}m`}
              </p>
              <p className="muted">
                차량별 경로 탐색은 아직 구현되지 않았습니다. 판정 엔진과 경로 탐색은 7·8단계에서 추가됩니다.
              </p>
            </div>
          )}

          <form
            className="search"
            onSubmit={(e) => {
              e.preventDefault();
              void runSearch();
            }}
          >
            <div className="seg" role="radiogroup" aria-label="검색 종류">
              <button type="button" role="radio" aria-checked={mode === 'address'} onClick={() => setMode('address')}>
                주소
              </button>
              <button type="button" role="radio" aria-checked={mode === 'keyword'} onClick={() => setMode('keyword')}>
                장소명
              </button>
            </div>
            <div className="search-row">
              <label htmlFor="q" className="sr-only">
                {mode === 'address' ? '주소 검색어' : '장소명 검색어'}
              </label>
              <input
                id="q"
                type="search"
                inputMode="search"
                autoComplete="off"
                placeholder={mode === 'address' ? '예: 순천시 장명로 30' : '예: 순천역'}
                value={query}
                maxLength={60}
                onChange={(e) => setQuery(e.target.value)}
                disabled={searchDisabled}
              />
              <button type="submit" className="primary" disabled={searchDisabled || busy}>
                {busy ? '검색 중' : '검색'}
              </button>
            </div>
          </form>

          {pausedUntil !== null && (
            <div className="alert" role="alert">
              <p>
                검색 서버 오류가 반복되어 {new Date(pausedUntil).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit' })}
                까지 검색을 멈췄습니다. 일일 사용량 한도에 도달했을 수 있습니다.
              </p>
              <p>지도 보기, 현재 위치, 지도에서 목적지 선택은 계속 사용할 수 있습니다.</p>
            </div>
          )}
          {msg && <p className="hint" role="status">{msg}</p>}

          {results.length > 0 && (
            <ol className="results" aria-label="검색 결과">
              {results.slice(0, 15).map((r, i) => (
                <li key={r.id}>
                  <span className="result-no" aria-hidden="true">{i + 1}</span>
                  <div className="result-text">
                    <strong>{r.name}</strong>
                    {r.address !== r.name && <span>{r.address}</span>}
                  </div>
                  <div className="result-actions">
                    <button type="button" onClick={() => choose(r, 'origin')}>출발지로</button>
                    <button type="button" className="primary" onClick={() => choose(r, 'dest')}>목적지로</button>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </div>

        <footer className="panel-foot">
          <span>이 기기 오늘 검색 {calls}회</span>
          {gps.kind === 'ok' && <span>위치 정확도 약 {Math.round(gps.accuracy)}m</span>}
        </footer>
      </section>

      <section className="map-wrap" aria-label="지도">
        <div ref={mapEl} className="map" />
        {mapState === 'loading' && <div className="map-state">지도를 불러오는 중입니다</div>}
        {mapState === 'failed' && (
          <div className="map-state is-error" role="alert">
            <p>{mapError}</p>
            <button type="button" className="primary" onClick={() => window.location.reload()}>
              다시 불러오기
            </button>
          </div>
        )}
        {mapState === 'ready' && (
          <div className="map-tools">
            <button
              type="button"
              className={pickMode ? 'tool is-active' : 'tool'}
              aria-pressed={pickMode}
              onClick={() => setPickMode((v) => !v)}
            >
              {pickMode ? '지도를 눌러 목적지 지정' : '지도에서 목적지 선택'}
            </button>
            <button type="button" className="tool" onClick={locate} disabled={gps.kind === 'locating'}>
              {gps.kind === 'locating' ? '위치 확인 중' : '현재 위치'}
            </button>
          </div>
        )}
        {gps.kind === 'error' && mapState === 'ready' && (
          <p className="map-toast" role="alert">{gps.message}</p>
        )}
      </section>
    </div>
  );
}
