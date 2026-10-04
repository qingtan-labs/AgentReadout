'use client';

import { useEffect, useState } from 'react';
import Image from 'next/image';

type Language = 'zh' | 'en';
const repository = 'https://github.com/qingtan-labs/GaugeForCodex';
const release = `${repository}/releases/latest`;
const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? '';

const copy = {
  zh: {
    nav: ['功能', '每日 Token', '隐私', '下载'],
    badge: '原生 macOS 菜单栏应用 · 开源',
    title: '看清每一份',
    titleAccent: 'AI 使用空间。',
    intro: 'Codex 与 Claude 的额度、重置时间和每日 Token，一眼读懂。不打断工作，也不用多开一个网页。',
    download: '下载 macOS 版本',
    source: '查看 GitHub',
    compatibility: '适用于 macOS 12+ · Apple 芯片与 Intel',
    preview: '界面示意 · 数值仅供展示',
    remaining: '剩余额度',
    reset: '后重置',
    today: '今日 Token',
    week: '近 7 天',
    overview: '你的 AI 工作台，保持轻盈。',
    overviewBody: '重要信息留在菜单栏；需要细看时，再打开完整视图。',
    featureEyebrow: '为日常使用而设计',
    featureTitle: '少一点猜测，多一点把握。',
    features: [
      ['双服务额度', '在同一处查看 Codex 和 Claude 的可用额度、会员等级与重置时间。未启用的服务会清楚提示。'],
      ['按你的习惯显示', '菜单栏、桌面组件和悬浮组件各司其职。进度条为默认样式，也可以切换成环形。'],
      ['及时而不过度', '自动同步、低额度提醒和最近一次有效数据，让关键变化不会被错过。'],
    ],
    tokenEyebrow: '使用记录',
    tokenTitle: '每天用了多少 Token，直接看。',
    tokenBody: '展示 Codex 提供的每日用量与累计指标。Claude 仅在现成客户端缓存可用时显示，不自行编造缺失的数据，也不另建用量历史。',
    tokenSource: '来自现有数据源',
    tokenNoCost: '不显示费用估算',
    tokenWeek: '最近七天 · 示例',
    tokenTotal: '累计 Token',
    tokenPeak: '单日峰值',
    tokenStreak: '当前连续',
    widgetEyebrow: '桌面组件',
    widgetTitle: '抬眼就知道，还剩多少。',
    widgetBody: '额度与每日 Token 都支持小、中、大号原生组件。大号 Token 组件还能呈现累计用量、单日峰值与连续使用等指标。macOS 12–13 可使用悬浮组件。',
    widgetCaption: '组件示意 · WidgetKit 需要 macOS 14+',
    privacyEyebrow: '隐私优先',
    privacyTitle: '只读必要数据，不碰你的对话。',
    privacyBody: '应用在本机读取 Codex 的额度与每日统计，以及你选择启用的 Claude 用量来源；不会读取提示词或聊天内容。没有开发者运营的账户、遥测或广告 SDK。',
    privacyNotes: ['本机保存设置与必要的额度快照', 'Token 页面使用现有数据，不单独记录历史', '更新检查通过 GitHub；Claude 同步可能直连 Anthropic'],
    ctaEyebrow: '开始使用',
    ctaTitle: '让额度清楚可见，让注意力留给创作。',
    ctaBody: '免费下载，源码开放。安装后从菜单栏选择要显示的服务和组件样式。',
    codeTitle: '也可以从源码构建',
    footnote: 'AgentReadout 是独立的第三方开源工具，与 OpenAI 或 Anthropic 无隶属或背书关系。',
    privacyLink: '隐私说明',
    license: 'MIT 许可',
  },
  en: {
    nav: ['Features', 'Daily Tokens', 'Privacy', 'Download'],
    badge: 'Native macOS menu bar app · Open source',
    title: 'Know your AI',
    titleAccent: 'headroom.',
    intro: 'Codex and Claude limits, reset times, and daily Tokens in one clear view. Stay in your flow without opening another dashboard.',
    download: 'Download for macOS',
    source: 'View on GitHub',
    compatibility: 'macOS 12+ · Apple silicon and Intel',
    preview: 'Interface preview · sample values',
    remaining: 'Remaining',
    reset: 'until reset',
    today: 'Today’s Tokens',
    week: 'Last 7 days',
    overview: 'Your AI workspace, kept light.',
    overviewBody: 'The essentials stay in your menu bar. Open the full view when you need more detail.',
    featureEyebrow: 'Built for daily use',
    featureTitle: 'Less guessing. More clarity.',
    features: [
      ['Two services, one view', 'See Codex and Claude availability, plan tiers, and reset times together. Unconnected services get a clear explanation.'],
      ['Your way to glance', 'Menu bar, native widgets, and floating widgets each have a place. Bars are the default; rings are optional.'],
      ['Timely, not noisy', 'Automatic refresh, low-quota alerts, and the last valid snapshot keep meaningful changes visible.'],
    ],
    tokenEyebrow: 'Usage activity',
    tokenTitle: 'See your Tokens, day by day.',
    tokenBody: 'Read Codex daily usage and lifetime metrics from its existing source. Claude appears only when an existing client cache is available. Missing data is never invented or recorded into a new history.',
    tokenSource: 'Existing data sources',
    tokenNoCost: 'No cost estimates',
    tokenWeek: 'Last seven days · sample',
    tokenTotal: 'Lifetime Tokens',
    tokenPeak: 'Daily peak',
    tokenStreak: 'Current streak',
    widgetEyebrow: 'Desktop widgets',
    widgetTitle: 'One glance, and you know.',
    widgetBody: 'Quota and Daily Tokens both come in Small, Medium, and Large native widgets. The large Tokens widget adds lifetime usage, peak day, and streaks. A floating widget is available on macOS 12–13.',
    widgetCaption: 'Widget preview · WidgetKit requires macOS 14+',
    privacyEyebrow: 'Private by design',
    privacyTitle: 'Only the usage data. Never your chats.',
    privacyBody: 'The app reads Codex limits and daily statistics on your Mac, plus Claude sources you choose to enable. It does not read prompts or conversations. There is no developer-run account, telemetry, or ad SDK.',
    privacyNotes: ['Settings and necessary quota snapshots stay on your Mac', 'The Tokens view does not create a separate usage history', 'Update checks use GitHub; Claude sync may contact Anthropic'],
    ctaEyebrow: 'Get started',
    ctaTitle: 'Keep usage visible. Keep your focus on making.',
    ctaBody: 'Free to download and open source. Choose your services and widget style from the menu bar.',
    codeTitle: 'Or build from source',
    footnote: 'AgentReadout is an independent, unofficial open-source utility, not affiliated with or endorsed by OpenAI or Anthropic.',
    privacyLink: 'Privacy',
    license: 'MIT License',
  },
} as const;

const bars = [18, 31, 46, 34, 72, 94, 58];
const sampleDays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

function Brand({ compact = false }: { compact?: boolean }) {
  return <span className={`brand ${compact ? 'brand-compact' : ''}`}>
    <Image src={`${basePath}/brand-icon.png`} alt="" width={44} height={44} unoptimized />
    <span>Agent<span className="brand-light">Readout</span></span>
  </span>;
}
function ArrowIcon() {
  return <svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M4 10h11m-4-4 4 4-4 4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
function DownloadIcon() {
  return <svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M10 3v9m-3-3 3 3 3-3M4 15v2h12v-2" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}
function SectionLabel({ children }: { children: React.ReactNode }) {
  return <span className="section-label"><span className="label-dot" />{children}</span>;
}
function QuotaCard({ name, plan, amount, color, reset, remaining }: { name: string; plan: string; amount: number; color: 'mint' | 'coral'; reset: string; remaining: string }) {
  return <div className={`quota-card quota-${color}`}>
    <div className="quota-topline"><span className="provider"><i />{name}</span><span className="plan">{plan}</span></div>
    <div className="quota-numbers"><span>{remaining}</span><strong>{amount}<small>%</small></strong></div>
    <div className="quota-track"><span style={{ width: `${amount}%` }} /></div>
    <div className="quota-reset">{reset}</div>
  </div>;
}

export default function Home() {
  const [language, setLanguage] = useState<Language>('zh');
  const t = copy[language];
  useEffect(() => {
    const saved = window.localStorage.getItem('agentreadout-language');
    const preferred = saved === 'en' || saved === 'zh' ? saved : navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
    const frame = window.requestAnimationFrame(() => setLanguage(preferred));
    return () => window.cancelAnimationFrame(frame);
  }, []);
  useEffect(() => {
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    window.localStorage.setItem('agentreadout-language', language);
  }, [language]);
  useEffect(() => {
    const elements = document.querySelectorAll<HTMLElement>('[data-reveal]');
    if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12 });
    elements.forEach(element => { element.classList.add('will-reveal'); observer.observe(element); });
    return () => observer.disconnect();
  }, []);

  return <main id="top" className="site-shell">
    <div className="page-grid" aria-hidden="true" />
    <header className="site-header">
      <a href="#top" aria-label="AgentReadout home"><Brand /></a>
      <nav aria-label={language === 'zh' ? '主导航' : 'Primary navigation'}><a href="#features">{t.nav[0]}</a><a href="#tokens">{t.nav[1]}</a><a href="#privacy">{t.nav[2]}</a></nav>
      <div className="header-actions"><button type="button" className="language-button" onClick={() => setLanguage(language === 'zh' ? 'en' : 'zh')} aria-label={language === 'zh' ? 'Switch to English' : '切换为简体中文'}>{language === 'zh' ? 'EN' : '中'}</button><a className="header-download" href={release} target="_blank" rel="noreferrer">{t.nav[3]} <ArrowIcon /></a></div>
    </header>
    <section className="hero content-width">
      <div className="hero-copy" data-reveal><SectionLabel>{t.badge}</SectionLabel><h1>{t.title}<br /><em>{t.titleAccent}</em></h1><p>{t.intro}</p><div className="hero-actions"><a className="button-primary" href={release} target="_blank" rel="noreferrer"><DownloadIcon />{t.download}<ArrowIcon /></a><a className="button-secondary" href={repository} target="_blank" rel="noreferrer">{t.source}<ArrowIcon /></a></div><div className="compatibility"><span className="compatibility-check">✓</span>{t.compatibility}</div></div>
      <div className="hero-visual" data-reveal><div className="visual-halo" aria-hidden="true" /><div className="visual-orbit orbit-a" aria-hidden="true" /><div className="visual-orbit orbit-b" aria-hidden="true" /><div className="app-window"><div className="window-toolbar"><div className="traffic"><i /><i /><i /></div><span>AgentReadout</span><span className="toolbar-time">09:41</span></div><div className="window-content"><div className="window-title"><Brand compact /><span className="live-pill"><i /> LIVE</span></div><div className="window-subtitle">{t.remaining}</div><QuotaCard name="Codex" plan="Pro 5×" amount={68} color="mint" reset={`4h 32m ${t.reset}`} remaining="7d" /><QuotaCard name="Claude" plan="Pro" amount={91} color="coral" reset={`2h 18m ${t.reset}`} remaining="5h" /><div className="window-footer"><span>{t.today}</span><strong>2.4M</strong><div className="sparkline" aria-hidden="true"><i /><i /><i /><i /><i /><i /><i /></div></div></div></div><div className="floating-chip chip-quota"><span className="chip-ring">68%</span><span>Codex <small>7d</small></span></div><div className="preview-caption">{t.preview}</div></div>
    </section>
    <section className="intro-strip content-width" data-reveal><div><SectionLabel>AGENTREADOUT / 02</SectionLabel><h2>{t.overview}</h2><p>{t.overviewBody}</p></div><div className="intro-metrics"><span><b>02</b> Codex + Claude</span><span><b>03</b> {language === 'zh' ? '种组件尺寸' : 'widget sizes'}</span><span><b>00</b> {language === 'zh' ? '遥测' : 'telemetry'}</span></div></section>
    <section className="features-section content-width" id="features"><div className="section-heading" data-reveal><SectionLabel>{t.featureEyebrow}</SectionLabel><h2>{t.featureTitle}</h2></div><div className="feature-grid">{t.features.map((feature, index) => <article className="feature-card" data-reveal key={feature[0]}><span className="feature-number">0{index + 1}</span><div className={`feature-symbol feature-symbol-${index + 1}`} aria-hidden="true"><i /><i /><i /></div><h3>{feature[0]}</h3><p>{feature[1]}</p></article>)}</div></section>
    <section className="token-section" id="tokens">
      <div className="token-inner content-width">
        <div className="token-copy" data-reveal>
          <SectionLabel>{t.tokenEyebrow}</SectionLabel><h2>{t.tokenTitle}</h2><p>{t.tokenBody}</p>
          <div className="token-tags"><span>✓ {t.tokenSource}</span><span>✓ {t.tokenNoCost}</span></div>
        </div>
        <div className="token-panel" data-reveal>
          <div className="panel-head"><span>{t.tokenWeek}</span><span className="panel-source"><i /> Codex</span></div>
          <div className="chart" aria-hidden="true">
            {bars.map((bar, index) => <div className="chart-column" key={index}>
              <div className="bar-area"><i style={{ height: `${bar}%`, animationDelay: `${index * 85}ms` }} /></div>
              <span>{sampleDays[index]}</span>
            </div>)}
          </div>
          <table className="sr-only">
            <caption>{language === 'zh' ? '最近七天示例 Token 用量' : 'Sample Tokens for seven days'}</caption>
            <thead><tr><th scope="col">{language === 'zh' ? '日期' : 'Day'}</th><th scope="col">Tokens</th></tr></thead>
            <tbody>{bars.map((bar, index) => <tr key={index}><th scope="row">{index + 1}</th><td>{(bar * 24000).toLocaleString()}</td></tr>)}</tbody>
          </table>
          <div className="panel-stats"><div><small>{t.tokenTotal}</small><strong>53.9M</strong></div><div><small>{t.tokenPeak}</small><strong>3.9M</strong></div><div><small>{t.tokenStreak}</small><strong>4 {language === 'zh' ? '天' : 'days'}</strong></div></div>
        </div>
      </div>
    </section>
    <section className="widget-section content-width"><div className="widget-demo" data-reveal><div className="widget-small"><div className="widget-heading"><Image src={`${basePath}/brand-icon.png`} alt="" width={28} height={28} unoptimized /><span>AgentReadout</span></div><div className="widget-ring"><strong>68%</strong></div><div className="widget-service">Codex <span>7d</span></div></div><div className="widget-medium"><div className="widget-heading"><Image src={`${basePath}/brand-icon.png`} alt="" width={28} height={28} unoptimized /><span>{t.today}</span></div><div className="widget-main-value">2.4<span>M</span></div><div className="widget-mini-bars" aria-hidden="true">{bars.map((height, index) => <i key={index} style={{ height: `${Math.max(height, 20)}%` }} />)}</div><div className="widget-range">{t.week}</div></div><span className="widget-caption">{t.widgetCaption}</span></div><div className="widget-copy" data-reveal><SectionLabel>{t.widgetEyebrow}</SectionLabel><h2>{t.widgetTitle}</h2><p>{t.widgetBody}</p></div></section>
    <section className="privacy-section" id="privacy"><div className="privacy-inner content-width"><div className="privacy-copy" data-reveal><SectionLabel>{t.privacyEyebrow}</SectionLabel><h2>{t.privacyTitle}</h2><p>{t.privacyBody}</p></div><ul className="privacy-list" data-reveal>{t.privacyNotes.map(note => <li key={note}><span>✓</span>{note}</li>)}</ul></div></section>
    <section className="cta-section content-width" id="download" data-reveal><div className="cta-glow" aria-hidden="true" /><SectionLabel>{t.ctaEyebrow}</SectionLabel><h2>{t.ctaTitle}</h2><p>{t.ctaBody}</p><div className="hero-actions"><a className="button-primary" href={release} target="_blank" rel="noreferrer"><DownloadIcon />{t.download}<ArrowIcon /></a><a className="button-secondary" href={repository} target="_blank" rel="noreferrer">{t.source}<ArrowIcon /></a></div><details className="source-details"><summary>{t.codeTitle}</summary><pre>git clone https://github.com/qingtan-labs/GaugeForCodex.git<br />cd GaugeForCodex/quota-overlay<br />./install.sh</pre></details></section>
    <footer className="site-footer content-width"><div><Brand /><p>{t.footnote}</p></div><nav aria-label="Footer"><a href={repository} target="_blank" rel="noreferrer">GitHub</a><a href={`${repository}/blob/main/PRIVACY.md`} target="_blank" rel="noreferrer">{t.privacyLink}</a><a href={`${repository}/blob/main/LICENSE`} target="_blank" rel="noreferrer">{t.license}</a></nav><span>© 2026 qingtan-labs</span></footer>
  </main>;
}
