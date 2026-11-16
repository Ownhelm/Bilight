import { useId, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import type Artplayer from 'artplayer';
import { CaretLeft, CaretRight, Check, Gear, X } from '@phosphor-icons/react';
import type { Playback, Subtitle } from '../shared/types';
import './playerSettings.css';

export const playbackSpeeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
export const defaultDanmakuStyle = { fontSize: 22, area: 0.5, opacity: 0.8 };
export type DanmakuStyle = typeof defaultDanmakuStyle;
type Panel = 'quality' | 'speed' | 'subtitle' | 'danmaku';
type SettingsProps = {
  player: Artplayer;
  data: Playback | null;
  pendingQuality?: number;
  qualityError: string;
  selectQuality: (quality: number) => void;
  speed: number;
  setSpeed: (speed: number) => void;
  subtitles: Subtitle[];
  subtitleId: string;
  setSubtitle: (id: string) => void;
  subtitleError?: string;
  retrySubtitle: () => void;
  danmaku: boolean;
  setDanmaku: (enabled: boolean) => void;
  danmakuStyle: DanmakuStyle;
  setDanmakuStyle: (style: DanmakuStyle) => void;
};
const sectionLabels = { quality: '清晰度', speed: '倍速', subtitle: '字幕', danmaku: '弹幕样式' };

export function PlayerSettings(props: SettingsProps) {
  const { player, data, pendingQuality, qualityError, selectQuality, speed, setSpeed, subtitles, subtitleId, setSubtitle, subtitleError, retrySubtitle, danmaku, setDanmaku, danmakuStyle, setDanmakuStyle } = props;
  const [open, setOpen] = useState(false);
  const [section, setSection] = useState<Panel | null>(null);
  const gear = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const surface = player.template.$player;
  const id = useId();

  function close() {
    setOpen(false);
    setSection(null);
    gear.current?.focus({ preventScroll: true });
  }
  useLayoutEffect(() => {
    if (!open || !gear.current || !panel.current) return;
    const menu = panel.current;
    const anchor = gear.current;
    const align = () => {
      const bounds = surface.getBoundingClientRect();
      const rect = anchor.getBoundingClientRect();
      const progress = player.template.$progress.getBoundingClientRect();
      menu.style.setProperty('--bilight-settings-end', `${Math.max(8, bounds.right - rect.right)}px`);
      menu.style.setProperty('--bilight-settings-bottom', `${Math.max(0, bounds.bottom - progress.top + 6)}px`);
    };
    const keepVisible = (visible: boolean) => { if (!visible) player.controls.show = true; };
    const outside = (event: PointerEvent) => {
      if (event.target instanceof Node && !surface.contains(event.target)) { setOpen(false); setSection(null); }
    };
    player.on('control', keepVisible);
    player.controls.show = true;
    align();
    const resize = new ResizeObserver(align);
    resize.observe(surface);
    resize.observe(player.template.$controls);
    document.addEventListener('pointerdown', outside, true);
    return () => {
      resize.disconnect();
      document.removeEventListener('pointerdown', outside, true);
      player.off('control', keepVisible);
      if (!player.isDestroy) player.controls.show = true;
    };
  }, [open, player, surface]);
  useLayoutEffect(() => {
    if (open) panel.current?.querySelector<HTMLElement>('.player-settings-heading button')?.focus({ preventScroll: true });
  }, [open, section]);

  const qualityLabel = data?.qualities.find(item => item.id === data.quality)?.label ?? '';
  const pendingQualityLabel = data?.qualities.find(item => item.id === pendingQuality)?.label ?? '';
  const subtitleLabel = subtitles.find(item => item.id === subtitleId)?.label ?? (subtitles.length ? '关闭' : '不可用');
  const navigation = (key: Panel, value: string) => <button type="button" className="player-settings-row" onClick={() => setSection(key)}>
    <span>{sectionLabels[key]}</span><span className="player-settings-value">{value}<CaretRight size={14} /></span>
  </button>;
  let body: ReactNode;
  switch (section) {
    case 'quality': body = <>
      {data?.qualities.map(item => <SettingChoice key={item.id} selected={item.id === data.quality} onClick={() => selectQuality(item.id)} label={item.label} />)}
      <p className="player-settings-note">档位由当前视频和账号提供</p>
      {pendingQualityLabel && <p className="player-settings-note" role="status">正在切换到 {pendingQualityLabel}</p>}
      {qualityError && <p className="player-settings-problem" role="alert">{qualityError}</p>}
    </>; break;
    case 'speed': body = playbackSpeeds.map(rate => <SettingChoice key={rate} selected={rate === speed} onClick={() => setSpeed(rate)} label={`${rate}×`} />); break;
    case 'subtitle': body = subtitleError ? <p className="player-settings-problem" role="alert">{subtitleError} <button type="button" className="text-button" onClick={retrySubtitle}>重试</button></p> : subtitles.length ? <>
      {subtitles.map(item => <SettingChoice key={item.id} selected={item.id === subtitleId} onClick={() => setSubtitle(item.id)} label={item.label} />)}
      <SettingChoice selected={!subtitleId} onClick={() => setSubtitle('')} label="关闭字幕" />
    </> : <p className="player-settings-note">当前分 P 暂无可用字幕</p>; break;
    case 'danmaku': body = <>
      <DanmakuChoices label="字号" value={danmakuStyle.fontSize} options={[[17, '小'], [22, '标准'], [29, '大']]} onChange={fontSize => setDanmakuStyle({ ...danmakuStyle, fontSize })} />
      <DanmakuChoices label="显示区域" value={danmakuStyle.area} options={[[0.25, '1/4'], [0.5, '1/2'], [0.75, '3/4'], [1, '全屏']]} onChange={area => setDanmakuStyle({ ...danmakuStyle, area })} />
      <DanmakuChoices label="不透明度" value={danmakuStyle.opacity} options={[[0.5, '50%'], [0.8, '80%'], [1, '100%']]} onChange={opacity => setDanmakuStyle({ ...danmakuStyle, opacity })} />
    </>; break;
    default: body = <>
      {navigation('quality', pendingQualityLabel ? '正在切换…' : qualityLabel)}
      {navigation('speed', `${speed}×`)}
      {navigation('subtitle', subtitleLabel)}
      <div className="player-settings-row player-settings-danmaku">
        {danmaku ? <button type="button" onClick={() => setSection('danmaku')}>弹幕<CaretRight size={14} /></button> : <span>弹幕</span>}
        <button type="button" className={danmaku ? 'active' : undefined} role="switch" aria-label="弹幕" aria-checked={danmaku} onClick={() => setDanmaku(!danmaku)}><span className="toggle-track" aria-hidden="true"><span /></span></button>
      </div>
    </>;
  }
  return <>
    <button type="button" className="player-settings-gear" ref={gear} aria-label="播放设置" aria-haspopup="dialog" aria-expanded={open} aria-controls={open ? id : undefined}
      onKeyDown={event => { if (event.key === ' ' || event.key === 'Enter') event.stopPropagation(); }}
      onClick={event => { event.stopPropagation(); if (open) close(); else setOpen(true); }}><Gear size={23} /></button>
    {open && createPortal(<>
      <div className="player-settings-dismiss" aria-hidden="true" onClick={event => { event.stopPropagation(); close(); }} />
      <div ref={panel} className="player-settings-panel" id={id} role="dialog" aria-labelledby={`${id}-title`}
        onClick={event => event.stopPropagation()}
        onKeyDown={event => {
          event.stopPropagation();
          if (event.key === 'Escape') { event.preventDefault(); close(); }
        }}>
        <div className="player-settings-heading">
          {section && <button type="button" className="player-settings-back" onClick={() => setSection(null)}><CaretLeft size={14} />设置</button>}
          <h2 id={`${id}-title`}>{section ? sectionLabels[section] : '播放设置'}</h2>
          <button type="button" aria-label="关闭播放设置" onClick={close}><X size={15} /></button>
        </div>
        <div className="player-settings-content" key={section ?? 'main'}>{body}</div>
      </div>
    </>, surface)}
  </>;
}

function SettingChoice({ selected, onClick, label }: { selected: boolean; onClick: () => void; label: string }) {
  return <button type="button" className="player-settings-row player-settings-choice" aria-pressed={selected} onClick={onClick}>
    <span>{label}</span>{selected && <Check size={17} aria-hidden="true" />}
  </button>;
}

function DanmakuChoices({ label, value, options, onChange }: { label: string; value: number; options: [number, string][]; onChange: (value: number) => void }) {
  return <div className="player-settings-segment" role="group" aria-label={label}>
    <p>{label}</p>
    <div>{options.map(([choice, title]) => <button type="button" aria-pressed={choice === value} key={choice} onClick={() => onChange(choice)}>{title}</button>)}</div>
  </div>;
}
