// Tizen 5/6 TVs run Chromium 56-76, which ignore every declaration using clamp() (Chromium 79+).
// For each declaration containing clamp(min, preferred, max) this plugin inserts, just before it,
// a copy where clamp() is replaced by its preferred value. Old engines keep that copy (the next
// declaration is invalid for them); modern engines override it with the real clamp().

function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === '(') depth += 1;
    else if (ch === ')') depth -= 1;
    else if (ch === ',' && depth === 0) {
      parts.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(text.slice(start).trim());
  return parts;
}

function replaceClamp(value) {
  let out = value;
  let idx = out.indexOf('clamp(');
  while (idx !== -1) {
    let depth = 0;
    let end = -1;
    for (let i = idx + 5; i < out.length; i += 1) {
      if (out[i] === '(') depth += 1;
      else if (out[i] === ')') {
        depth -= 1;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end === -1) break;
    const args = splitTopLevel(out.slice(idx + 6, end));
    const preferred = args.length === 3 ? args[1] : args[0];
    out = out.slice(0, idx) + preferred + out.slice(end + 1);
    idx = out.indexOf('clamp(');
  }
  return out;
}

module.exports = () => ({
  postcssPlugin: 'clamp-fallback',
  Declaration(decl) {
    if (!decl.value || !decl.value.includes('clamp(')) return;
    decl.cloneBefore({ value: replaceClamp(decl.value) });
  },
});
module.exports.postcss = true;
