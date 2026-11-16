import type { CommentMention } from '../shared/types';

export function mentionAt(text: string, start: number, end: number) {
  if (start !== end) return null;
  const token = /[@＠]([^@＠\s，。！？；：、]{0,40})$/u.exec(text.slice(0, start));
  if (!token || (token.index > 0 && /[A-Za-z0-9._%+-]/.test(text[token.index - 1]))) return null;
  return { start: token.index, end: start, query: token[1] };
}

export function commentParts(text: string, mentions: CommentMention[], emotes: Record<string, string> = {}) {
  const pieces: { text: string; user?: CommentMention; emote?: string }[] = [];
  const byName = new Map(mentions.filter(user => user.name).map(user => [user.name, user]));
  const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const longestFirst = (a: string, b: string) => b.length - a.length;
  const names = [...byName.keys()].sort(longestFirst).map(escape);
  const emoteTokens = Object.keys(emotes).filter(Boolean).sort(longestFirst).map(escape);
  const patterns = names.length ? [`@(${names.join('|')})(?=\\s|$)`, ...emoteTokens] : emoteTokens;
  if (!patterns.length) return [{ text }];
  const matches = text.matchAll(new RegExp(patterns.join('|'), 'gu'));
  let end = 0;
  for (const match of matches) {
    if (match.index > end) pieces.push({ text: text.slice(end, match.index) });
    pieces.push({ text: match[0], user: byName.get(match[1]), emote: Object.hasOwn(emotes, match[0]) ? emotes[match[0]] : undefined });
    end = match.index + match[0].length;
  }
  if (end < text.length) pieces.push({ text: text.slice(end) });
  return pieces;
}
