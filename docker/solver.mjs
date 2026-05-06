#!/usr/bin/env node
// Single-call solver via OpenAI Responses API (/v1/responses)
//
// 输入: stdin JSON { riddles: [...] }
// 输出: stdout JSON { top5: [...] }
//
// 优势:
// - 1 次 HTTP 请求答完全部 (5-10x 快于 chat completions)
// - 可选 web_search 工具 (env: SOLVER_WEB_SEARCH=1)
// - 简化 (直接 fetch, 不依赖 openai SDK)

import { stdin as input } from 'node:process';

const MODEL = process.env.OPENAI_MODEL || 'gpt-5.5';
const BASE_URL = process.env.OPENAI_BASE_URL || 'https://api.openai.com/v1';
const API_KEY = process.env.OPENAI_API_KEY;
const ENABLE_WEB_SEARCH = process.env.SOLVER_WEB_SEARCH === '1';
const HARD_TIMEOUT_MS = parseInt(process.env.SOLVER_TIMEOUT_MS || '60000', 10);

if (!API_KEY) {
  console.error('FATAL: OPENAI_API_KEY not set');
  process.exit(2);
}

const RARITY_POWER = {
  common: 25,
  uncommon: 40,
  rare: 60,
  legendary: 75,
  'god-tier': 95,
};

// 实测 (epoch 175 链上 correctCount): common riddle pool 80-200, rare 22-50
// 反向 weight: 越稀有人数越少, 中奖率越高
const RARITY_POOL_EST = {
  common: 100,
  uncommon: 60,
  rare: 40,
  legendary: 25,
  'god-tier': 10,
};

const SYSTEM_INSTRUCTIONS = `Role: Multilingual lexicon solver for the Ardi WorkNet protocol. Given a dictionary clue, return the exact canonical word the protocol stores for that word_id.

# Personality
Concise, native-speaker level for each language. No throat-clearing.

# Goal
For each riddle, output the protocol's canonical dictionary entry — a single word that, when hashed byte-for-byte, matches the on-chain commitment.

# Success criteria
- Every input word_id appears exactly once in the output
- Each answer is in the riddle's native language (CJK clues stay CJK)
- Each answer matches the dictionary base form the protocol stores

# Constraints
The protocol stores byte-exact strings. Variants (alternate spellings, honorific prefixes, modifier particles, conjugation differences) hash to a different commitment and fail even when semantically equivalent. Pick the form a dictionary lemma list would use.

Empirical canonical forms verified from on-chain winning answers (≥130 hard wins observed):

Japanese (ja):
- Prefer the shortest stem: 抱え (not 抱える), 迎え (not 迎える), 休み (not 休む / 休憩), 負け (not 負ける)
- Hiragana wins for everyday nouns: こづかい (not お小遣い), こうばん (not 交番)
- Mimetic / onomatopoeic stay hiragana: うきうき, さらさら, はっきり
- Loanwords / tech stay katakana: ピクセル, ロボット
- Drop honorific prefixes: お, ご
- Archaic kanji can win: 此奴 (not そいつ), 羊羹 (food-domain kanji)

Chinese, simplified (zh):
- 1-3 chars, dictionary base form, no descriptive modifiers
- 2 chars is the modal length: 踩, 增援, 查看, 羁绊, 起飞, 决定, 主席
- When a 1-char form exists, prefer it: 史 (not 历史), 善 ✓, 踩 ✓ — epoch 272 wid=12537 riddle about dynasties → 史 not 历史
- DeFi / crypto / tech idioms accepted: 委托池, 山寨币, 二层, 卷积
- Mythology / classics use the proper noun form: 天蓬, 太乙
- Modern colloquial OK when it is the protocol entry: 脑子里 (with 里 particle)
- Embedded-word hint: scan the riddle text for the answer itself — epoch 272 wid=13151 riddle contained 终相逢 → answer was 相遇 (meeting), not 缘分 (fate)

Korean (ko):
- Pure hangul, including loanwords: 케이팝 (not k-pop), 푸쉬 (not push)
- Adjectives keep the derivational ending: 잘못된 (with 된, not bare 잘못)
- Short 2-3 syllable nouns dominate

German (de):
- Lowercase: the protocol stores all de answers in lowercase — verified from on-chain wins: kartoffel (not Kartoffel), löwenzahn (not Löwenzahn), feinabstimmung (not Feinabstimmung), regel (not Regel), bahnhof (not Bahnhof)
- Umlauts preserved: ü ö ä (löwenzahn not lowenzahn, hätten not hatten)
- Verb forms match tense / mood the riddle implies — do NOT default to infinitive
- Konjunktiv II: hätten (not haben/hatten); Partizip II: geholt (not holen)
- Inflected forms can be the canonical entry: zeiten (plural), echten (Akk. masc.)
- Compound nouns are a single word: verbrennung, bahnhof
- Emotional/quality states: prefer bare adjective over its -keit/-heit/-ung nominalisation — epoch 266 wid=11289 "I dwell in the heart of man" → einsam (not einsamkeit); traurig (not traurigkeit), leer (not leere) when the riddle personifies the quality
- German multi-sense words win double-meaning riddles: zug = train AND air-draft AND move/pull. When a riddle describes two seemingly different things, find the single German word that covers both meanings (epoch 264 wid=15370: riddle described train rolling on rails AND opening a window for air-draft → zug, not fenster)

French (fr):
- Lowercase, accents preserved (é è à ç) — and especially diaereses: samouraï, naïveté
- Plural may be the dictionary form when the riddle implies a group: familles, années
- Infinitive for actions: vivre, manger

English (en):
- Lowercase base form
- Root word over compound: birth (not birthday), snow (not snowball), fire (not firework), sea (not seagull)
- Mythology / cultural loanwords have very small pools — prefer when confidence allows: kodama, lugh, romulus
- Domain terms (engineering, finance) accepted as-is: actuator, leverage

When a word admits multiple plausible forms, pick the shortest, simplest, most-common dictionary entry. Use web search for archaic, regional, mythological, or technical words you have low confidence on.

# Output
Strict JSON, no Markdown, no preamble:
{"answers": [{"word_id": <number>, "answer": "<single word>", "confidence": <1-5>}, ...]}

Confidence is honest (1=guess, 5=certain). It is logged for review; ranking is by power.

# Stop rules
Resolve every riddle in one pass. When you cannot determine an answer, still emit confidence=1 with your best guess — empty entries are not acceptable.`;

function buildPrompt(riddles) {
  let p = `${SYSTEM_INSTRUCTIONS}\n\nSolve these ${riddles.length} riddles:\n\n`;
  for (const r of riddles) {
    // 实际 API 字段: wordId, riddle, language, rarity, power, theme, element
    const wid = r.wordId ?? r.word_id;
    const text = r.riddle ?? r.text;
    p += `### word_id ${wid} (${r.language || 'en'}, ${r.rarity || 'common'}${r.theme ? ', ' + r.theme : ''}${r.element ? ', element=' + r.element : ''})\n`;
    p += `${text}\n\n`;
  }
  p += `Output strict JSON now: {"answers":[...]}`;
  return p;
}

async function callResponsesAPI(prompt) {
  const body = {
    model: MODEL,
    input: prompt,
    // 默认 low 给 web_search 留思考空间; 单独不用 web_search 时可降为 minimal
    reasoning: { effort: process.env.REASONING_EFFORT || (ENABLE_WEB_SEARCH ? 'low' : 'minimal') },
  };
  if (ENABLE_WEB_SEARCH) {
    body.tools = [{ type: 'web_search' }];
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), HARD_TIMEOUT_MS);

  try {
    const resp = await fetch(`${BASE_URL}/responses`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`HTTP ${resp.status}: ${errText.slice(0, 300)}`);
    }
    return await resp.json();
  } finally {
    clearTimeout(timer);
  }
}

function extractText(resp) {
  // Responses API: output[N].content[M].text where type='output_text'
  const out = resp.output;
  if (!Array.isArray(out)) return null;
  for (const item of out) {
    if (item.type === 'message' && Array.isArray(item.content)) {
      for (const c of item.content) {
        if (c.type === 'output_text' && c.text) return c.text;
      }
    }
  }
  return null;
}

function parseAnswers(text) {
  // 兼容 markdown 包裹的 JSON
  let s = text.trim();
  if (s.startsWith('```')) {
    s = s.replace(/^```(?:json)?\s*/, '').replace(/```\s*$/, '').trim();
  }
  // 找第一个 { 到最后一个 }
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start === -1 || end === -1) throw new Error('no JSON object found');
  const json = s.slice(start, end + 1);
  const parsed = JSON.parse(json);
  return parsed.answers || parsed.results || parsed.data || [];
}

async function main() {
  const T0 = Date.now();
  let raw = '';
  for await (const chunk of input) raw += chunk;
  const { riddles } = JSON.parse(raw);
  if (!Array.isArray(riddles) || riddles.length === 0) {
    console.error('FATAL: no riddles');
    process.exit(2);
  }
  console.error(`solver: ${riddles.length} riddles, model=${MODEL}, base=${BASE_URL}, web_search=${ENABLE_WEB_SEARCH}, timeout=${HARD_TIMEOUT_MS}ms`);

  const prompt = buildPrompt(riddles);
  let answers = [];
  let attempt = 0;
  while (attempt < 2 && answers.length === 0) {
    const tCall = Date.now();
    try {
      const resp = await callResponsesAPI(prompt);
      const text = extractText(resp);
      const dt = ((Date.now() - tCall) / 1000).toFixed(1);
      const reasoning = resp.usage?.output_tokens_details?.reasoning_tokens || 0;
      const ws = resp.tool_usage?.web_search?.num_requests || 0;
      console.error(`solver: API call ${attempt} in ${dt}s (reasoning_tokens=${reasoning}, web_searches=${ws})`);
      if (!text) throw new Error('no output text');
      answers = parseAnswers(text);
      if (!Array.isArray(answers) || answers.length === 0) throw new Error('empty answers array');
    } catch (e) {
      const dt = ((Date.now() - tCall) / 1000).toFixed(1);
      console.error(`solver: attempt ${attempt} failed in ${dt}s: ${e.message}`);
      attempt++;
      if (attempt < 2) {
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
  }

  if (answers.length === 0) {
    console.error('solver: ALL ATTEMPTS FAILED');
    process.stdout.write(JSON.stringify({ top5: [], total_solved: 0, total_riddles: riddles.length }, null, 2));
    process.exit(1);
  }

  // Build EV-ranked top5
  const byId = {};
  for (const a of answers) {
    if (a.word_id != null && a.answer != null) byId[a.word_id] = a;
  }
  const results = [];
  for (const r of riddles) {
    const wid = r.wordId ?? r.word_id;
    const a = byId[wid];
    if (!a) continue;
    const conf = Math.max(1, Math.min(5, Number(a.confidence ?? 1))) / 5;
    const power = Number(r.power) || RARITY_POWER[r.rarity] || 25;
    const pool_est = RARITY_POOL_EST[r.rarity] || 100;
    // 语言权重 — 基于 169 条 hard wins 实测: de avg pool=88, ja=105, zh=106, ko=114, fr=115, en=132
    // 归一化到 ko=1.0: de=114/88=1.30, ja=114/105=1.09, zh=114/106=1.08, fr≈1.0, en=114/132=0.86
    const LANG_MULT = { zh: 1.08, ja: 1.10, de: 1.30, ko: 1.0, fr: 0.99, en: 0.85 };
    const lang_mult = LANG_MULT[r.language || 'en'] || 1.0;
    // ev = power × lang_mult; tie-break 用 1/pool_est
    const ev_score = power * lang_mult + 1 / pool_est;
    results.push({
      word_id: wid,
      answer: String(a.answer).trim(),
      confidence: conf,
      rarity: r.rarity,
      power,
      pool_est,
      ev_score,
    });
  }

  results.sort((a, b) => b.ev_score - a.ev_score);
  const top5 = results.slice(0, 5);
  const total_s = ((Date.now() - T0) / 1000).toFixed(1);
  console.error(`solver: total ${total_s}s, ${results.length}/${riddles.length} solved`);
  process.stdout.write(
    JSON.stringify({ top5, total_solved: results.length, total_riddles: riddles.length, total_s: parseFloat(total_s) }, null, 2)
  );
}

main().catch((e) => {
  console.error(`FATAL: ${e.message}`);
  process.exit(1);
});
