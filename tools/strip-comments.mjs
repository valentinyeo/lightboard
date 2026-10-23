#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const extensions = { '.zig': 'zig', '.js': 'javascript', '.ts': 'typescript', '.mjs': 'javascript', '.cjs': 'javascript', '.jsx': 'javascript', '.tsx': 'typescript', '.py': 'python', '.kt': 'kotlin', '.kts': 'kotlin', '.java': 'java', '.ps1': 'powershell', '.psm1': 'powershell', '.sh': 'shell', '.bash': 'shell', '.c': 'c', '.h': 'c', '.cpp': 'c', '.hpp': 'c', '.rc': 'c', '.css': 'css', '.html': 'html', '.yml': 'yaml', '.yaml': 'yaml', '.toml': 'toml' };
const excluded = new Set(['third_party', 'third-party', 'vendor', 'vendored', 'node_modules', 'skillsrepo', 'openwiki', 'docs', 'docs-site', '.git', '.zig-cache', 'zig-out', 'build', 'generated']);
const operators = ['>>>=', '===', '!==', '**=', '&&=', '||=', '??=', '>>>', '<<=', '>>=', '...', '=>', '==', '!=', '<=', '>=', '++', '--', '&&', '||', '??', '?.', '**', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>', '::', '->', '..', '##'];
const white = c => c !== undefined && /\s/.test(c);
const wordStart = c => c !== undefined && /[\p{L}_$]/u.test(c);
const wordPart = c => c !== undefined && /[\p{L}\p{N}_$]/u.test(c);
const jsLanguages = new Set(['javascript', 'typescript']);

function keptReason(text, start, source) {
  if (start === 0 && text.startsWith('#!')) return 'shebang';
  if (/eslint-(?:disable|enable)|@ts-(?:check|nocheck|ignore|expect-error)|prettier-ignore|#\s*type:\s*ignore|#\s*noqa\b|#.*coding[:=]|#Requires\b|#\s*shellcheck\b|\/\/\s*noinspection\b/i.test(text)) return 'tool directive';
  if (/^# v[0-9]+[ \t]*$/.test(text) && /^[ \t]*(?:-[ \t]+)?uses:[ \t]+[\w.-]+\/[\w./-]+@[0-9a-f]{40}[ \t]+$/.test(source.slice(source.lastIndexOf('\n', start - 1) + 1, start))) return 'tool directive';
  return null;
}

function quoted(source, start, quote, escape = '\\', doubled = false) {
  let i = start + quote.length;
  while (i < source.length) {
    if (escape && source[i] === escape) { i += 2; continue; }
    if (source.startsWith(quote, i)) {
      if (doubled && source.startsWith(quote + quote, i)) { i += quote.length * 2; continue; }
      return i + quote.length;
    }
    i++;
  }
  throw new Error(`Unterminated ${quote} at ${start}`);
}

function pythonLex(source) {
  const program = String.raw`
import ast, io, json, token, tokenize, sys
s = json.load(sys.stdin)
lines = s.splitlines(keepends=True)
off = [0]
for line in lines: off.append(off[-1] + len(line))
def pos(p): return off[p[0]-1] + p[1]
def apos(line, col): return off[line-1] + len(lines[line-1].encode('utf-8')[:col].decode('utf-8'))
def u16(n): return len(s[:n].encode('utf-16-le')) // 2
root = ast.parse(s)
docs = []
for parent in ast.walk(root):
    for field, body in ast.iter_fields(parent):
        if not isinstance(body, list): continue
        for node in body:
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                a, b = apos(node.lineno,node.col_offset), apos(node.end_lineno,node.end_col_offset)
                reason = None
                if len(body) == 1 and not isinstance(parent, ast.Module): reason = 'sole suite statement (syntax/behaviour)'
                if s[off[node.lineno-1]:a].strip() or s[b:off[node.end_lineno]].strip().startswith(';'): reason = 'inline suite/semicolon (syntax/behaviour)'
                if any(isinstance(n, ast.Attribute) and n.attr == '__doc__' or isinstance(n, ast.Name) and n.id == '__doc__' for n in ast.walk(root)): reason = 'runtime __doc__ access'
                if 'doctest' in s: reason = 'doctest input'
                docs.append((a,b,reason))
out, comments = [], []
for t in tokenize.generate_tokens(io.StringIO(s).readline):
    a,b = pos(t.start),pos(t.end)
    if t.type == tokenize.COMMENT: comments.append([u16(a),u16(b),None]); continue
    doc = next((d for d in docs if d[0] <= a and b <= d[1]), None)
    if doc and doc[2] is None: continue
    if t.type in (tokenize.ENCODING,tokenize.ENDMARKER,tokenize.NL): continue
    if t.type == tokenize.NEWLINE and any(d[2] is None and d[1] == a for d in docs): continue
    out.append([token.tok_name[t.type], t.string if t.type not in (tokenize.INDENT,tokenize.DEDENT,tokenize.NEWLINE) else ''])
for a,b,reason in docs: comments.append([u16(a),u16(b),reason or 'docstring'])
print(json.dumps({'tokens':out,'comments':comments}))
`;
  const result = spawnSync('python3', ['-c', program], { input: JSON.stringify(source), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr);
  const parsed = JSON.parse(result.stdout);
  return { tokens: parsed.tokens, comments: parsed.comments.map(([start, end, reason]) => ({ start, end, reason: reason === 'docstring' ? null : reason, docstring: reason !== null })) };
}

export function tokenize(source, language) {
  const result = lex(source, language);
  const mask = new Uint8Array(source.length);
  for (const c of result.comments) {
    mask.fill(1, c.start, c.end);
    c.reason ||= keptReason(source.slice(c.start, c.end), c.start, source);
  }
  let firstCode = 0;
  while (firstCode < source.length && (mask[firstCode] || white(source[firstCode]))) firstCode++;
  const header = result.comments.filter(c => c.end <= firstCode);
  if (header.some(c => /copyright|SPDX-License-Identifier|SPDX-FileCopyrightText|\blicen[cs]e\b|all rights reserved/i.test(source.slice(c.start, c.end)))) {
    for (const c of header) c.reason ||= 'license/copyright header';
  }
  return result;
}

function lex(source, language) {
  if (language === 'python') return pythonLex(source);
  if (language === 'yaml') return yamlLex(source);
  if (language === 'toml') return tomlLex(source);
  const tokens = [], comments = [];
  let i = 0, expression = true, previous = '', pendingControl = false;
  const parens = [], braces = [];
  function token(start, end, kind = 'code') {
    const value = source.slice(start, end);
    tokens.push([kind, value]);
    return value;
  }
  function comment(start, end) {
    comments.push({ start, end, reason: keptReason(source.slice(start, end), start, source) });
    i = end;
  }
  function lineEnd(start) {
    let end = source.indexOf('\n', start);
    if (end < 0) end = source.length;
    if (source[end - 1] === '\r') end--;
    return end;
  }
  function blockEnd(start, open, close, nested = false) {
    let end = start + open.length, depth = 1;
    while (end < source.length) {
      if (nested && source.startsWith(open, end)) { depth++; end += open.length; }
      else if (source.startsWith(close, end)) { depth--; end += close.length; if (!depth) return end; }
      else end++;
    }
    throw new Error(`Unterminated comment at ${start}`);
  }
  function template(start) {
    let end = start + 1;
    while (end < source.length) {
      if (source[end] === '\\') { end += 2; continue; }
      if (source[end] === '`') return end + 1;
      if (source.startsWith('${', end)) { end = interpolation(end + 2); continue; }
      end++;
    }
    throw new Error(`Unterminated template at ${start}`);
  }
  function interpolation(start) {
    let end = start, depth = 1, canRegex = true;
    while (end < source.length) {
      const c = source[end];
      if (white(c)) { end++; continue; }
      if (c === '"' || c === "'") { end = quoted(source, end, c); canRegex = false; continue; }
      if (c === '`') { end = template(end); canRegex = false; continue; }
      if (source.startsWith('//', end)) { end = lineEnd(end); continue; }
      if (source.startsWith('/*', end)) { end = blockEnd(end, '/*', '*/'); continue; }
      if (c === '/' && canRegex) { end = regexEnd(end); canRegex = false; continue; }
      if (c === '{') depth++;
      if (c === '}' && --depth === 0) return end + 1;
      if (c !== '}') {
        if (wordStart(c)) {
          const a = end++; while (wordPart(source[end])) end++;
          canRegex = ['return', 'throw', 'yield', 'typeof', 'void', 'delete', 'new', 'in', 'of', 'await'].includes(source.slice(a, end));
          continue;
        }
        canRegex = !/[\p{N}\])]/u.test(c);
      }
      end++;
    }
    throw new Error(`Unterminated interpolation at ${start}`);
  }
  function regexEnd(start) {
    let end = start + 1, inClass = false;
    while (end < source.length) {
      const c = source[end];
      if (c === '\\') { end += 2; continue; }
      if (c === '[') inClass = true;
      if (c === ']') inClass = false;
      if (c === '/' && !inClass) {
        end++; while (wordPart(source[end])) end++;
        return end;
      }
      if (c === '\n' || c === '\r') break;
      end++;
    }
    throw new Error(`Unterminated regex at ${start}`);
  }
  if (language === 'shell') return shellLex(source);
  if (language === 'html') return htmlLex(source);
  while (i < source.length) {
    const start = i, c = source[i];
    if (white(c)) { i++; continue; }
    if (i === 0 && source.startsWith('#!')) { comment(i, lineEnd(i)); continue; }
    if (language === 'zig' && source.startsWith('\\\\', i)) {
      i = lineEnd(i); token(start, i, 'string'); expression = false; continue;
    }
    if (language === 'powershell' && (source.startsWith("@'", i) || source.startsWith('@"', i)) && /^@['"][ \t]*\r?\n/.test(source.slice(i))) {
      const delimiter = source[i + 1] + '@';
      i = lineEnd(i) + 1;
      while (i < source.length && !source.startsWith(delimiter, i)) i = lineEnd(i) + (source[lineEnd(i)] === '\r' ? 2 : 1);
      if (i >= source.length) throw new Error(`Unterminated here-string at ${start}`);
      i += 2; token(start, i, 'string'); continue;
    }
    if (language === 'powershell' && source.startsWith('<#', i)) { comment(i, blockEnd(i, '<#', '#>', true)); continue; }
    if (language === 'powershell' && c === '#') { comment(i, lineEnd(i)); continue; }
    if (language !== 'powershell' && language !== 'css' && source.startsWith('//', i)) {
      let end = lineEnd(i);
      if (language === 'c') while (source[end - 1] === '\\' && end < source.length) end = lineEnd(end + (source[end] === '\r' ? 2 : 1));
      comment(i, end); continue;
    }
    if (language !== 'powershell' && source.startsWith('/*', i)) { comment(i, blockEnd(i, '/*', '*/', language === 'kotlin')); continue; }
    if (language === 'c' && source.startsWith('R"', i)) {
      const opening = source.indexOf('(', i + 2);
      if (opening < 0) throw new Error('Invalid C++ raw string');
      const delimiter = ')' + source.slice(i + 2, opening) + '"';
      const end = source.indexOf(delimiter, opening + 1);
      if (end < 0) throw new Error('Unterminated C++ raw string');
      i = end + delimiter.length; token(start, i, 'string'); continue;
    }
    if (c === '"' || c === "'" || (language === 'kotlin' && c === '`')) {
      const triple = (language === 'kotlin' || language === 'java') && source.startsWith('"""', i);
      const escape = language === 'powershell' ? (c === '"' ? '`' : '') : triple ? '' : '\\';
      i = quoted(source, i, triple ? '"""' : c, escape, language === 'powershell');
      token(start, i, 'string'); expression = false; previous = 'literal'; continue;
    }
    if (jsLanguages.has(language) && c === '`') { i = template(i); token(start, i, 'string'); expression = false; previous = 'literal'; continue; }
    if (jsLanguages.has(language) && c === '/' && expression) { i = regexEnd(i); token(start, i, 'regex'); expression = false; previous = 'literal'; continue; }
    if (language === 'powershell' && c === '`') { i += 2; token(start, i); continue; }
    if (wordStart(c) || (language === 'c' && c === '\\')) {
      i++; while (wordPart(source[i]) || source[i] === '\\' && language === 'c') i++;
      const value = token(start, i, 'word');
      if (jsLanguages.has(language)) {
        pendingControl = ['if', 'while', 'for', 'with', 'switch', 'catch'].includes(value);
        expression = ['return', 'throw', 'case', 'delete', 'void', 'typeof', 'instanceof', 'in', 'of', 'yield', 'await', 'new', 'else', 'do'].includes(value);
      }
      previous = value; continue;
    }
    if (/[0-9]/.test(c)) {
      i++; while (/[\w.]/.test(source[i] || '') || /[+-]/.test(source[i] || '') && /[eEpP]/.test(source[i - 1])) i++;
      token(start, i, 'number'); expression = false; previous = 'literal'; continue;
    }
    const op = operators.find(value => source.startsWith(value, i)) || c;
    i += op.length; token(start, i);
    if (jsLanguages.has(language)) {
      if (op === '(') { parens.push(pendingControl ? 'control' : 'expression'); pendingControl = false; expression = true; }
      else if (op === ')') expression = parens.pop() === 'control';
      else if (op === '{') { braces.push(expression && !['=', '(', '[', ',', ':', 'return'].includes(previous) || previous === '=>' || previous === ')' || previous === 'else' || previous === 'try' || previous === 'finally' ? 'block' : 'object'); expression = true; }
      else if (op === '}') expression = braces.pop() === 'block';
      else expression = ![']', '++', '--', '.', '?.'].includes(op);
    }
    previous = op;
  }
  return { tokens, comments };
}

function yamlLex(source) {
  const tokens = [], comments = [];
  let i = 0, plain = false, block = null, flow = 0;
  const endLine = start => { const end = source.indexOf('\n', start); return end < 0 ? source.length : end; };
  while (i < source.length) {
    const start = i, c = source[i];
    if (c === '\n') {
      i++; plain = false;
      if (block) {
        const body = i;
        let indent = block.explicit ? block.indent + block.explicit : null;
        while (i < source.length) {
          const end = endLine(i), line = source.slice(i, end), spaces = /^[ ]*/.exec(line)[0].length;
          if (line.trim()) {
            if (indent === null) { if (spaces <= block.indent) break; indent = spaces; }
            if (spaces < indent) break;
          }
          i = Math.min(source.length, end + 1);
        }
        if (i > body) tokens.push(['scalar', source.slice(body, i)]);
        block = null;
      }
      continue;
    }
    if (white(c)) { i++; continue; }
    if (c === '#' && (i === 0 || white(source[i - 1]))) {
      i = endLine(i); if (source[i - 1] === '\r') i--;
      comments.push({ start, end: i, reason: keptReason(source.slice(start, i), start, source) }); continue;
    }
    if (source.startsWith('${{', i)) {
      i += 3;
      while (i < source.length && !source.startsWith('}}', i)) {
        if (source[i] === "'" || source[i] === '"') i = quoted(source, i, source[i], source[i] === '"' ? '\\' : '', true); else i++;
      }
      if (i >= source.length) throw new Error(`Unterminated YAML expression at ${start}`);
      i += 2; tokens.push(['expression', source.slice(start, i)]); plain = true; continue;
    }
    if (!plain && (c === '"' || c === "'")) { i = quoted(source, i, c, c === '"' ? '\\' : '', c === "'"); tokens.push(['string', source.slice(start, i)]); continue; }
    const marker = !plain && !flow && /^[|>](?:[1-9][+-]?|[+-][1-9]?)?(?=[ \t\r\n]|$)/.exec(source.slice(i));
    if (marker) {
      const line = source.slice(source.lastIndexOf('\n', i - 1) + 1, i);
      block = { indent: /^[ ]*/.exec(line)[0].length, explicit: Number(/[1-9]/.exec(marker[0])?.[0] || 0) };
      i += marker[0].length; tokens.push(['code', marker[0]]); continue;
    }
    if (!plain && '[{'.includes(c)) { flow++; plain = false; }
    else if (flow && ']}'.includes(c)) { flow--; plain = false; }
    else if (flow && c === ',' || c === ':' && (white(source[i + 1]) || source[i + 1] === undefined || flow && '[]{},'.includes(source[i + 1])) || !plain && '-?:'.includes(c) && white(source[i + 1])) plain = false;
    else plain = true;
    i++; tokens.push(['code', c]);
  }
  return { tokens, comments };
}

function tomlLex(source) {
  const tokens = [], comments = [];
  let i = 0;
  while (i < source.length) {
    const start = i, c = source[i];
    if (white(c)) { i++; continue; }
    if (c === '#') {
      const end = source.indexOf('\n', i); i = end < 0 ? source.length : end; if (source[i - 1] === '\r') i--;
      comments.push({ start, end: i, reason: keptReason(source.slice(start, i), start, source) }); continue;
    }
    if (c === '"' || c === "'") {
      const triple = source.startsWith(c.repeat(3), i);
      if (!triple) i = quoted(source, i, c, c === '"' ? '\\' : '');
      else {
        i += 3;
        while (i < source.length && !source.startsWith(c.repeat(3), i)) { if (c === '"' && source[i] === '\\') i += 2; else i++; }
        if (i >= source.length) throw new Error(`Unterminated TOML string at ${start}`);
        i += 3; while (source[i] === c) i++;
      }
      tokens.push(['string', source.slice(start, i)]); continue;
    }
    i++; tokens.push(['code', c]);
  }
  return { tokens, comments };
}

function shellLex(source) {
  const tokens = [], comments = [];
  let i = 0, atWordStart = true;
  const heredocs = [];
  const endLine = start => { const end = source.indexOf('\n', start); return end < 0 ? source.length : end; };
  function quote(start, q) {
    let end = start + 1;
    while (end < source.length) {
      if (q !== "'" && source[end] === '\\') { end += 2; continue; }
      if (q === '"' && source.startsWith('$(', end)) { end = substitution(end + 2); continue; }
      if (source[end] === q) return end + 1;
      end++;
    }
    throw new Error(`Unterminated shell quote at ${start}`);
  }
  function substitution(start) {
    let end = start, depth = 1;
    while (end < source.length) {
      const c = source[end];
      if (c === '\\') { end += 2; continue; }
      if (c === '"' || c === "'" || c === '`') { end = quote(end, c); continue; }
      if (c === '(') depth++;
      if (c === ')' && --depth === 0) return end + 1;
      end++;
    }
    throw new Error(`Unterminated shell substitution at ${start}`);
  }
  while (i < source.length) {
    const start = i, c = source[i];
    if (c === '\n') {
      i++; tokens.push(['newline', '\n']); atWordStart = true;
      for (const { delimiter, tabs } of heredocs.splice(0)) {
        const body = i;
        while (i < source.length && (tabs ? source.slice(i, endLine(i)).replace(/^\t*/, '') : source.slice(i, endLine(i))).replace(/\r$/, '') !== delimiter) i = endLine(i) + 1;
        if (i >= source.length) throw new Error(`Unterminated heredoc ${delimiter}`);
        i = Math.min(source.length, endLine(i) + 1); tokens.push(['heredoc', source.slice(body, i)]);
      }
      continue;
    }
    if (white(c)) { i++; atWordStart = true; continue; }
    if (c === '#' && atWordStart) {
      i = endLine(i); comments.push({ start, end: i, reason: keptReason(source.slice(start, i), start, source) }); continue;
    }
    if (source.startsWith('<<<', i)) { i += 3; tokens.push(['operator', '<<<']); atWordStart = true; continue; }
    if (source.startsWith('<<', i)) {
      i += 2; const tabs = source[i] === '-'; if (tabs) i++;
      tokens.push(['operator', source.slice(start, i)]);
      while (/[ \t]/.test(source[i] || '')) i++;
      const delimiterStart = i;
      let delimiter = '';
      while (i < source.length && !white(source[i]) && !';|&()<>'.includes(source[i])) {
        if (source[i] === "'" || source[i] === '"') { const end = quote(i, source[i]); delimiter += source.slice(i + 1, end - 1); i = end; }
        else if (source[i] === '\\') { delimiter += source[i + 1]; i += 2; }
        else delimiter += source[i++];
      }
      if (!delimiter) throw new Error('Missing heredoc delimiter');
      heredocs.push({ delimiter, tabs }); tokens.push(['word', source.slice(delimiterStart, i)]); atWordStart = false; continue;
    }
    if (';|&()<>'.includes(c)) { i++; tokens.push(['operator', c]); atWordStart = true; continue; }
    while (i < source.length && !white(source[i]) && !';|&()<>'.includes(source[i])) {
      if (source[i] === "'" || source[i] === '"' || source[i] === '`') i = quote(i, source[i]);
      else if (source.startsWith('$(', i)) i = substitution(i + 2);
      else if (source[i] === '\\') i += 2;
      else i++;
    }
    tokens.push(['word', source.slice(start, i)]); atWordStart = false;
  }
  return { tokens: tokens.filter((t, n) => t[0] !== 'newline' || tokens[n - 1]?.[0] !== 'newline' && n !== 0), comments };
}

function htmlLex(source) {
  const tokens = [], comments = [];
  let i = 0;
  while (i < source.length) {
    const start = i;
    if (source.startsWith('<!--', i)) {
      const end = source.indexOf('-->', i + 4);
      if (end < 0) throw new Error('Unterminated HTML comment');
      i = end + 3; comments.push({ start, end: i, reason: keptReason(source.slice(start, i), start, source) }); continue;
    }
    if (source[i] === '<') {
      const match = /^<([\w-]+)/.exec(source.slice(i));
      while (i < source.length && source[i] !== '>') {
        if (source[i] === '"' || source[i] === "'") i = quoted(source, i, source[i], ''); else i++;
      }
      i++; tokens.push(['tag', source.slice(start, i)]);
      const tag = match?.[1].toLowerCase();
      if (['script', 'style', 'textarea', 'pre'].includes(tag)) {
        const close = new RegExp(`</${tag}\\s*>`, 'ig'); close.lastIndex = i;
        const end = close.exec(source);
        if (!end) throw new Error(`Missing closing ${tag}`);
        if (tag === 'script' || tag === 'style') {
          const child = tokenize(source.slice(i, end.index), tag === 'script' ? 'javascript' : 'css');
          tokens.push(...child.tokens); comments.push(...child.comments.map(c => ({ ...c, start: c.start + i, end: c.end + i })));
        } else tokens.push(['text', source.slice(i, end.index)]);
        i = end.index;
      }
    } else {
      while (i < source.length && source[i] !== '<') i++;
      const value = source.slice(start, i);
      if (value.trim()) tokens.push(['text', value]);
    }
  }
  return { tokens, comments };
}

export function strip(source, language) {
  const lexed = tokenize(source, language);
  const ranges = lexed.comments.filter(c => !c.reason);
  const removed = new Uint8Array(source.length);
  const separators = new Set();
  for (const c of ranges) {
    removed.fill(1, c.start, c.end);
    if (c.start > 0 && !white(source[c.start - 1]) && c.end < source.length && !white(source[c.end]) && !source.slice(c.start, c.end).includes('\n')) separators.add(c.start);
  }
  let output = '', offset = 0, linesRemoved = 0, commentLines = 0;
  for (const line of source.match(/[^\n]*\n|[^\n]+$/g) || []) {
    let changed = false, value = '';
    for (let j = 0; j < line.length; j++) {
      if (removed[offset + j]) { changed = true; if (line[j] === '\n') value += '\n'; else if (separators.has(offset + j)) value += ' '; }
      else value += line[j];
    }
    if (changed) {
      commentLines++;
      const eol = value.endsWith('\r\n') ? '\r\n' : value.endsWith('\n') ? '\n' : '';
      let body = value.slice(0, value.length - eol.length).replace(/[ \t\r]+$/, '');
      if (!body.trim()) { linesRemoved++; value = ''; }
      else value = body + eol;
    }
    output += value; offset += line.length;
  }
  if (JSON.stringify(lexed.tokens) !== JSON.stringify(tokenize(output, language).tokens)) throw new Error(`Removal changes ${language} tokens`);
  return { output, commentLines, linesRemoved, kept: lexed.comments.filter(c => c.reason).map(c => ({ line: source.slice(0, c.start).split('\n').length, reason: c.reason, text: source.slice(c.start, c.end) })) };
}

export function languageFor(file, source = '') {
  if (file.split('/').some(p => excluded.has(p)) || file.startsWith('gradle/wrapper/') || /(^|\/)README(?:\.|$)/i.test(file)) return null;
  if (/\.(?:md|mdx|json|jsonc|zon|xml|properties|svg)$/i.test(file)) return null;
  if (/(?:@generated|auto-generated|automatically generated|generated by)/i.test(source.slice(0, 1000))) return null;
  if (path.extname(file) === '.html' && !/^(?:src|assets|extension|app\/src\/main\/assets)\//.test(file)) return null;
  return extensions[path.extname(file)] || (source.startsWith('#!/bin/sh') || /^#!.*\b(?:bash|sh)\b/.test(source.split('\n')[0]) ? 'shell' : null);
}

export function verifyTokens(before, after, language) {
  if (JSON.stringify(tokenize(before, language).tokens) !== JSON.stringify(tokenize(after, language).tokens)) throw new Error(`Non-comment ${language} token stream changed`);
}

function git(root, args) { return execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }); }

export function run(root, { verify = false, check = false, base = 'HEAD', exemptions = [] } = {}) {
  root = path.resolve(root);
  const files = git(root, ['ls-files', '-z']).split('\0').filter(Boolean);
  const report = { root, base, filesChanged: 0, languages: {}, kept: [], exemptions, found: [] };
  const baseFiles = new Set(verify ? git(root, ['ls-tree', '-r', '--name-only', '-z', base]).split('\0') : []);
  for (const file of files) {
    const full = path.join(root, file);
    if (!fs.lstatSync(full).isFile()) continue;
    const buffer = fs.readFileSync(full);
    if (buffer.includes(0)) {
      if (verify && baseFiles.has(file)) {
        const original = execFileSync('git', ['-C', root, 'cat-file', '--filters', `${base}:${file}`], { maxBuffer: 64 * 1024 * 1024 });
        if (!original.equals(buffer)) throw new Error(`Protected binary file changed: ${file}`);
      }
      continue;
    }
    const current = buffer.toString('utf8');
    const before = verify && baseFiles.has(file) ? git(root, ['cat-file', '--filters', `${base}:${file}`]) : current;
    const language = languageFor(file, before);
    if (!language) {
      if (verify && before !== current) throw new Error(`Protected file changed: ${file}`);
      continue;
    }
    if (check) {
      let comments;
      try { comments = tokenize(current, language).comments; } catch (error) { throw new Error(`${file}: ${error.message}`, { cause: error }); }
      for (const c of comments.filter(c => !c.reason)) report.found.push({ file, line: current.slice(0, c.start).split('\n').length, text: current.slice(c.start, c.end).split('\n')[0].slice(0, 120) });
      continue;
    }
    let result;
    try { result = strip(before, language); } catch (error) { throw new Error(`${file}: ${error.message}`, { cause: error }); }
    if (verify) {
      if (exemptions.includes(file)) {
        if (!/^(?:tools|extension)\/.*\.test\.js$|^tools\/patch-[^/]+\.py$/.test(file)) throw new Error(`Not a test/comment-anchor tool exemption: ${file}`);
      } else {
        verifyTokens(before, current, language);
        if (language !== 'zig' && result.output !== current) throw new Error(`Not the exact comment-only output: ${file}`);
      }
      const remaining = strip(current, language);
      if (remaining.output !== current) throw new Error(`Removable comments remain: ${file}`);
      const protectedComments = result => JSON.stringify(result.kept.map(({ reason, text }) => [reason, text]));
      if (protectedComments(result) !== protectedComments(remaining)) throw new Error(`Protected comments changed: ${file}`);
    } else if (result.output !== current) fs.writeFileSync(full, result.output);
    const after = verify ? current : result.output;
    const stat = report.languages[language] ||= { filesChanged: 0, commentLinesRemoved: 0, emptyLinesRemoved: 0 };
    if (before !== after || verify && !baseFiles.has(file)) { report.filesChanged++; stat.filesChanged++; stat.commentLinesRemoved += result.commentLines; stat.emptyLinesRemoved += result.linesRemoved; }
    for (const kept of result.kept) report.kept.push({ file, language, ...kept });
  }
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let verify = false, check = false, base = 'HEAD', root = '.', exemptions = [];
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg === '--verify') verify = true;
    else if (arg === '--check') check = true;
    else if (arg === '--base') base = process.argv[++i];
    else if (arg === '--exempt') exemptions.push(process.argv[++i]);
    else if (arg === '--exempt-file') exemptions.push(...JSON.parse(fs.readFileSync(process.argv[++i], 'utf8')));
    else if (arg.startsWith('-')) throw new Error(`Unknown option ${arg}`);
    else root = arg;
  }
  const report = run(root, { verify, check, base, exemptions });
  if (!check) console.log(JSON.stringify(report, null, 2));
  else if (report.found.length) {
    for (const f of report.found) console.error(`${f.file}:${f.line}: ${f.text}`);
    console.error(`${report.found.length} code comment(s) found. This repo keeps no code comments: name things so the code explains itself, and put reasons in the commit message or PR.`);
    process.exit(1);
  } else console.log('No code comments found.');
}
