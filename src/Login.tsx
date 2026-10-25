import { useEffect, useRef, useState } from 'react';
import QRCode from 'qrcode';
import { ArrowSquareOut, CheckCircle, DeviceMobile, QrCode, SpinnerGap, X } from '@phosphor-icons/react';
import type { CaptchaChallenge, Country, LoginResult, QrChallenge, QrState, SmsSend, SmsTicket } from '../shared/types';
import { api, errorMessage, isAbort, officialVerificationUrl } from './api';
import { Loading } from './components';

interface GeetestResult { geetest_challenge: string; geetest_validate: string; geetest_seccode: string }
interface Geetest {
  onReady(callback: () => void): Geetest; onSuccess(callback: () => void): Geetest;
  onError(callback: () => void): Geetest; onClose?(callback: () => void): Geetest;
  verify(): void; getValidate(): GeetestResult | false; destroy?(): void;
}
declare global { interface Window { initGeetest?: (options: Record<string, unknown>, callback: (captcha: Geetest) => void) => void } }
let geetestScript: Promise<void> | undefined;
function loadGeetest(): Promise<void> {
  if (window.initGeetest) return Promise.resolve();
  if (!geetestScript) geetestScript = new Promise<void>((resolve, reject) => {
    const script = document.createElement('script'); script.src = 'https://static.geetest.com/static/tools/gt.js'; script.async = true;
    script.onload = () => window.initGeetest ? resolve() : reject(new Error('安全验证未能加载，请重试。'));
    script.onerror = () => { script.remove(); reject(new Error('安全验证未能加载，请检查网络后重试。')); };
    document.head.appendChild(script);
  }).catch(error => { geetestScript = undefined; throw error; });
  return geetestScript;
}

export function Login({ onClose, onSuccess }: { onClose: () => void; onSuccess: () => Promise<void> }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [mode, setMode] = useState<'qr' | 'sms'>('qr');
  useEffect(() => {
    const element = dialog.current; element?.showModal();
    const oldOverflow = document.body.style.overflow; document.body.style.overflow = 'hidden';
    return () => { element?.close(); document.body.style.overflow = oldOverflow; };
  }, []);
  return <dialog ref={dialog} className="login-dialog" aria-labelledby="login-title" onCancel={onClose} onClick={event => { if (event.target === event.currentTarget) onClose(); }}>
    <div className="login-surface"><button className="icon-button modal-close" aria-label="关闭登录" onClick={onClose}><X /></button>
      <span className="login-label">BILIGHT ACCOUNT</span><h2 id="login-title">登录你的哔哩哔哩</h2><p className="login-intro">连接账号后，查看你关注的更新。</p>
      <div className="login-tabs" role="tablist" aria-label="登录方式"><button role="tab" aria-selected={mode === 'qr'} className={mode === 'qr' ? 'active' : ''} onClick={() => setMode('qr')}><QrCode size={19} />扫码登录</button><button role="tab" aria-selected={mode === 'sms'} className={mode === 'sms' ? 'active' : ''} onClick={() => setMode('sms')}><DeviceMobile size={19} />短信登录</button></div>
      {mode === 'qr' ? <QrLogin onSuccess={onSuccess} /> : <SmsLogin onSuccess={onSuccess} />}
      <p className="login-note">使用哔哩哔哩账号，无需注册新账号。登录凭据只保存在你的本地服务中。</p>
    </div>
  </dialog>;
}

function Verification({ url, onDone }: { url?: string; onDone: () => void }) {
  const safeUrl = officialVerificationUrl(url);
  return <div className="verification"><CheckCircle size={31} weight="light" /><h3>还需要完成一次安全验证</h3><p>请在哔哩哔哩官方页面完成验证，然后重新登录。</p>{safeUrl ? <a className="button button-primary" href={safeUrl} target="_blank" rel="noopener noreferrer">打开官方验证<ArrowSquareOut size={16} /></a> : <p className="field-error">未收到有效的官方验证链接，请重试登录。</p>}<button className="text-button" onClick={onDone}>已完成，重新登录</button></div>;
}

function QrLogin({ onSuccess }: { onSuccess: () => Promise<void> }) {
  const [generation, setGeneration] = useState(0);
  const [image, setImage] = useState('');
  const [state, setState] = useState<QrState['state']>('waiting');
  const [verificationUrl, setVerificationUrl] = useState<string>();
  const [error, setError] = useState('');
  useEffect(() => {
    const controller = new AbortController(); let timer: ReturnType<typeof setTimeout> | undefined;
    setImage(''); setState('waiting'); setError('');
    async function start() {
      try {
        const challenge = await api<QrChallenge>('/api/auth/qr', { method: 'POST', signal: controller.signal });
        const data = await QRCode.toDataURL(challenge.url, { width: 240, margin: 2, color: { dark: '#202128', light: '#ffffff' }, errorCorrectionLevel: 'M' });
        if (controller.signal.aborted) return;
        setImage(data);
        const expiry = challenge.expiresAt < 1e12 ? challenge.expiresAt * 1000 : challenge.expiresAt;
        async function poll() {
          if (controller.signal.aborted) return;
          if (Date.now() >= expiry) { setState('expired'); return; }
          try {
            const result = await api<QrState>(`/api/auth/qr/${encodeURIComponent(challenge.id)}`, { signal: controller.signal });
            if (controller.signal.aborted) return;
            setState(result.state); setVerificationUrl(result.verificationUrl);
            if (result.state === 'authenticated') { await onSuccess(); return; }
            if (result.state === 'expired' || result.state === 'verification_required') return;
            timer = setTimeout(poll, 2200);
          } catch (error) { if (!isAbort(error)) setError(errorMessage(error)); }
        }
        timer = setTimeout(poll, 1500);
      } catch (error) { if (!isAbort(error)) setError(errorMessage(error)); }
    }
    void start();
    return () => { controller.abort(); clearTimeout(timer); };
  }, [generation, onSuccess]);
  if (state === 'verification_required') return <Verification url={verificationUrl} onDone={() => setGeneration(value => value + 1)} />;
  return <div className="qr-login"><div className="qr-frame">
    {image ? <img className={state === 'expired' ? 'qr-expired' : ''} src={image} alt="哔哩哔哩登录二维码" width={216} height={216} /> : error ? <QrCode size={56} weight="light" /> : <SpinnerGap className="spin" size={30} />}
    {state === 'expired' && <div className="qr-overlay"><strong>二维码已过期</strong><button className="button button-primary" onClick={() => setGeneration(value => value + 1)}>刷新二维码</button></div>}
  </div>{state === 'scanned' ? <p className="qr-state"><CheckCircle weight="fill" />已扫码，请在手机上确认</p> : state === 'authenticated' ? <p className="qr-state">登录成功，正在连接</p> : <p className="qr-tip">打开哔哩哔哩 App，扫一扫登录</p>}
    {error && <div className="login-error" role="alert"><p>{error}</p><button className="text-button" onClick={() => setGeneration(value => value + 1)}>重新获取二维码</button></div>}
  </div>;
}

function SmsLogin({ onSuccess }: { onSuccess: () => Promise<void> }) {
  const [countries, setCountries] = useState<Country[]>([]);
  const [country, setCountry] = useState(1);
  const [tel, setTel] = useState(''); const [code, setCode] = useState('');
  const [ticket, setTicket] = useState<SmsTicket | null>(null);
  const [busy, setBusy] = useState(false); const [sending, setSending] = useState(false);
  const [error, setError] = useState(''); const [loadingCountries, setLoadingCountries] = useState(true);
  const [cooldown, setCooldown] = useState(0);
  const [verification, setVerification] = useState<LoginResult | null>(null);
  const active = useRef(true); const captchaRef = useRef<Geetest | null>(null); const requestRef = useRef<AbortController | null>(null);
  useEffect(() => {
    active.current = true; const controller = new AbortController();
    api<Country[]>('/api/auth/countries', { signal: controller.signal }).then(items => {
      if (!controller.signal.aborted) { setCountries(items); setCountry(items.find(item => String(item.code) === '86')?.id ?? items[0]?.id ?? 1); }
    }).catch(error => { if (!isAbort(error)) setError(errorMessage(error)); }).finally(() => { if (!controller.signal.aborted) setLoadingCountries(false); });
    return () => { active.current = false; controller.abort(); requestRef.current?.abort(); captchaRef.current?.destroy?.(); };
  }, []);
  useEffect(() => {
    if (cooldown <= 0) return;
    const timer = setTimeout(() => setCooldown(value => value - 1), 1000);
    return () => clearTimeout(timer);
  }, [cooldown]);
  function resetTicket() { setTicket(null); setCode(''); }
  async function send() {
    if (sending || cooldown || !tel.trim()) return;
    setError(''); setSending(true); resetTicket(); captchaRef.current?.destroy?.();
    const controller = new AbortController(); requestRef.current?.abort(); requestRef.current = controller;
    const currentTel = tel.trim(), currentCountry = country;
    try {
      const challenge = await api<CaptchaChallenge>('/api/auth/captcha', { method: 'POST', signal: controller.signal });
      await loadGeetest(); if (controller.signal.aborted) return;
      window.initGeetest!({ gt: challenge.gt, challenge: challenge.challenge, offline: false, new_captcha: true, product: 'bind', https: true, lang: 'zh-cn' }, captcha => {
        if (!active.current || controller.signal.aborted) { captcha.destroy?.(); return; }
        captchaRef.current = captcha;
        captcha.onReady(() => { if (!controller.signal.aborted) captcha.verify(); });
        captcha.onError(() => { if (active.current) { setError('安全验证未能完成，请重试。'); setSending(false); } });
        captcha.onClose?.(() => { if (active.current) setSending(false); });
        captcha.onSuccess(() => {
          const validation = captcha.getValidate();
          if (!validation || controller.signal.aborted) { setSending(false); return; }
          const body: SmsSend = { challengeId: challenge.id, tel: currentTel, cid: currentCountry, challenge: validation.geetest_challenge, validate: validation.geetest_validate, seccode: validation.geetest_seccode };
          api<SmsTicket>('/api/auth/sms/send', { method: 'POST', body, signal: controller.signal }).then(result => {
            if (!controller.signal.aborted) { setTicket(result); setCooldown(60); }
          }).catch(error => { if (!isAbort(error) && active.current) setError(errorMessage(error)); }).finally(() => { if (active.current && !controller.signal.aborted) setSending(false); });
        });
      });
    } catch (error) { if (!isAbort(error) && active.current) { setError(errorMessage(error)); setSending(false); } }
  }
  async function login(event: React.FormEvent) {
    event.preventDefault(); if (!ticket || busy) return;
    setBusy(true); setError(''); const controller = new AbortController(); requestRef.current = controller;
    try {
      const result = await api<LoginResult>('/api/auth/sms/login', { method: 'POST', body: { id: ticket.id, code }, signal: controller.signal });
      if (controller.signal.aborted) return;
      if (result.state === 'authenticated') await onSuccess(); else { setVerification(result); resetTicket(); }
    } catch (error) { if (!isAbort(error)) setError(errorMessage(error)); }
    finally { if (active.current) setBusy(false); }
  }
  if (verification) return <Verification url={verification.verificationUrl} onDone={() => setVerification(null)} />;
  if (loadingCountries) return <Loading text="正在准备登录" />;
  return <form className="sms-form" onSubmit={login}>
    <label htmlFor="login-tel">手机号码</label><div className="phone-field"><select aria-label="国家或地区区号" value={country} disabled={sending || busy} onChange={event => { setCountry(Number(event.target.value)); resetTicket(); }}>{countries.map(item => <option key={item.id} value={item.id}>{item.name} +{item.code}</option>)}</select><input id="login-tel" type="tel" autoComplete="tel-national" value={tel} placeholder="输入手机号码" disabled={sending || busy} maxLength={20} onChange={event => { setTel(event.target.value.replace(/[^0-9]/g, '')); resetTicket(); }} /></div>
    <label htmlFor="login-code">短信验证码</label><div className="code-field"><input id="login-code" inputMode="numeric" autoComplete="one-time-code" placeholder="输入验证码" value={code} maxLength={8} onChange={event => setCode(event.target.value.replace(/[^0-9]/g, ''))} /><button type="button" onClick={() => void send()} disabled={sending || busy || cooldown > 0 || tel.length < 5 || !countries.length}>{sending ? '安全验证中' : cooldown > 0 ? `${cooldown}s 后重发` : '获取验证码'}</button></div>
    {ticket && <p className="field-success">验证码已发送，请查看手机短信。</p>}{error && <p className="field-error" role="alert">{error}</p>}
    <button className="button button-primary login-submit" type="submit" disabled={!ticket || code.length < 4 || busy || sending}>{busy ? <><SpinnerGap className="spin" size={18} />正在登录</> : '登录'}</button>
  </form>;
}
