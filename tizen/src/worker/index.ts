/**
 * CND IPTV Tizen - Dedicated Web Worker (PRD 38 § 2.3)
 *
 * Runs off the main UI thread:
 * 1. WebAssembly cnd-domain-wasm module initialization and execution.
 * 2. Heavy M3U and XMLTV parsing via WebAssembly.
 * 3. Search query parsing and candidate ranking.
 * 4. Recommendation scoring and adult group filtering.
 */

import init, {
  wasm_get_schema_sql,
  wasm_is_adult_category,
  wasm_normalize_group_key,
  wasm_normalize_title,
  wasm_parse_m3u_chunk,
  wasm_parse_xmltv_chunk,
  wasm_parse_search_query,
  wasm_rank_search,
  wasm_score_recommendations,
  wasm_parse_saga_title,
  wasm_version,
} from '../wasm/pkg/cnd_domain_wasm.js';

let isWasmReady = false;

async function setup() {
  try {
    await init();
    isWasmReady = true;
    console.log('[Worker] cnd-domain-wasm initialized:', wasm_version());
  } catch (err) {
    console.error('[Worker] Failed to initialize wasm:', err);
  }
}

setup();

self.onmessage = async (e: MessageEvent) => {
  const { id, type, payload } = e.data;

  if (!isWasmReady) {
    await setup();
  }

  try {
    let result: any = null;

    switch (type) {
      case 'GET_VERSION':
        result = wasm_version();
        break;

      case 'GET_SCHEMA_SQL':
        result = wasm_get_schema_sql();
        break;

      case 'IS_ADULT_CATEGORY':
        result = wasm_is_adult_category(payload.group);
        break;

      case 'NORMALIZE_GROUP':
        result = wasm_normalize_group_key(payload.group);
        break;

      case 'NORMALIZE_TITLE':
        result = wasm_normalize_title(payload.raw, payload.group);
        break;

      case 'PARSE_M3U_CHUNK':
        result = wasm_parse_m3u_chunk(payload.content, payload.sourceUuid);
        break;

      case 'PARSE_XMLTV_CHUNK':
        result = wasm_parse_xmltv_chunk(payload.xmlContent, payload.cutoffTs);
        break;

      case 'PARSE_SEARCH_QUERY':
        result = wasm_parse_search_query(payload.query, payload.nowEpoch, payload.utcOffsetMinutes);
        break;

      case 'RANK_SEARCH':
        result = wasm_rank_search(JSON.stringify(payload.query), JSON.stringify(payload.candidates));
        break;

      case 'SCORE_RECOMMENDATIONS':
        result = wasm_score_recommendations(JSON.stringify(payload.taste), JSON.stringify(payload.items));
        break;

      case 'PARSE_SAGA_TITLE':
        result = wasm_parse_saga_title(payload.title, payload.year);
        break;

      default:
        throw new Error(`Unknown worker message type: ${type}`);
    }

    self.postMessage({ id, success: true, result });
  } catch (err: any) {
    self.postMessage({ id, success: false, error: err?.message || String(err) });
  }
};

