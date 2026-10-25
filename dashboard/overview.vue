<template>
  <main class="industrial-console" v-if="s">
    <div :class="['demo-banner', { 'hardware-banner': s.hardware_link_accepted }]"><span class="demo-dot"></span> {{ s.banner }} <span class="demo-note">{{ s.hardware_link_accepted ? 'Live hardware measurements accepted' : s.expected_source_mode === 'hardware' ? 'Waiting for live ESP32-S3 telemetry' : 'Simulated input · software test mode' }}</span></div>
    <header class="console-header">
      <div><div class="eyebrow">INDUSTRIAL TELEMETRY / GW-01</div><h1>Environmental gateway</h1><p>Modbus → MQTT · Read-only monitoring</p></div>
      <div class="header-status"><span :class="['state-pill', s.measurement_state]">{{ label(s.measurement_state) }}</span><small>{{ utc(s.receiver_ts_utc) }} UTC</small></div>
    </header>
    <section class="status-grid">
      <div class="status-cell"><span>MQTT transport</span><strong :class="tone(s.broker_state)">{{ label(s.broker_state) }}</strong></div>
      <div class="status-cell"><span>Gateway availability</span><strong :class="tone(s.gateway_state)">{{ label(s.gateway_state) }}</strong></div>
      <div class="status-cell"><span>Modbus source</span><strong :class="sourceStatusTone">{{ sourceStatusLabel }}</strong></div>
      <div class="status-cell"><span>Data origin</span><strong>{{ label(s.source_mode) }}</strong></div>
    </section>
    <div v-if="s.source_error || s.broker_state !== 'connected'" class="fault-bar" role="status"><strong>{{ s.broker_state !== 'connected' ? 'Broker connection unavailable' : 'Source requires attention' }}</strong><span>{{ s.source_error || 'Gateway availability cannot be confirmed while MQTT is disconnected.' }}</span><span v-if="s.values">Last valid reading preserved below.</span></div>
    <section class="reading-grid">
      <article :class="['reading-card', { dimmed: s.measurement_state === 'stale' }]">
        <div class="reading-top"><span class="sensor-mark temperature">T</span><span>Temperature</span><span class="register-tag">°C</span></div>
        <div class="reading-value">{{ number(s.values?.temperature_c) }}<span>°C</span></div>
        <div class="reading-caption">{{ readingCaption }}</div>
      </article>
      <article :class="['reading-card', { dimmed: s.measurement_state === 'stale' }]">
        <div class="reading-top"><span class="sensor-mark humidity">H</span><span>Relative humidity</span><span class="register-tag">% RH</span></div>
        <div class="reading-value">{{ number(s.values?.humidity_pct) }}<span>%</span></div>
        <div class="reading-caption">{{ readingCaption }}</div>
      </article>
      <article class="reading-card age-card">
        <div class="reading-top"><span>Age of last valid sample</span></div>
        <div class="reading-value age-value">{{ s.sample_age_ms === null ? '—' : (s.sample_age_ms / 1000).toFixed(1) }}<span>s</span></div>
        <div class="reading-caption">Stale after 10 s · UTC capture time</div>
      </article>
    </section>
    <section class="trend-panel">
      <div class="panel-heading"><div><h2>Recent measurements</h2><p>Up to 120 accepted samples · Duplicate and expired samples excluded</p></div><div class="chart-legend"><span class="temp-key">Temperature °C · left axis</span><span class="humidity-key">Humidity % RH · right axis</span></div></div>
      <div class="chart-empty" v-if="!s.history?.length"><strong>No data received</strong><span>Waiting for a fresh measurement from the selected gateway source.</span></div>
      <div v-else class="chart-wrap">
        <svg viewBox="0 0 1000 230" preserveAspectRatio="none" role="img" aria-label="Recent temperature and humidity trend; separate temperature and humidity scales">
          <g class="chart-grid"><line v-for="y in [24,70,116,162,208]" :key="y" x1="48" x2="948" :y1="y" :y2="y" /></g>
          <g class="axis-labels"><text x="6" y="28">{{ tempRange.max.toFixed(1) }}°</text><text x="6" y="212">{{ tempRange.min.toFixed(1) }}°</text><text x="955" y="28">100%</text><text x="955" y="212">0%</text></g>
          <polyline class="trend-temperature" :points="points('temperature_c')" /><polyline class="trend-humidity" :points="points('humidity_pct')" />
          <circle v-if="s.history.length === 1" :cx="48" :cy="pointY(s.history[0].temperature_c, 'temperature_c')" r="4" fill="#e9ad56" />
          <circle v-if="s.history.length === 1" :cx="48" :cy="pointY(s.history[0].humidity_pct, 'humidity_pct')" r="4" fill="#50c7be" />
        </svg>
        <div class="chart-times"><span>{{ time(s.history[0].at_ms) }} UTC</span><span>{{ time(s.history[s.history.length - 1].at_ms) }} UTC</span></div>
      </div>
    </section>
    <section class="detail-grid">
      <div><span>Accepted measurements</span><strong>{{ s.counters.good }}</strong></div><div><span>Source read errors</span><strong>{{ s.counters.bad }}</strong></div><div><span>Rejected messages</span><strong>{{ s.counters.rejected }}</strong></div><div><span>Last sequence</span><strong>{{ s.last_sample?.seq ?? '—' }}</strong></div>
    </section>
    <footer class="console-footer"><span>{{ s.validation_scope }}</span><span>{{ s.last_rejected ? 'Latest rejected message: ' + s.last_rejected.reason : 'Receiver active · Waiting for or processing telemetry' }}</span></footer>
    <details class="clock-note"><summary>Data freshness</summary><p>{{ s.receiver_clock_assumption }}</p><p>Gateway status needs a live, valid telemetry message after MQTT connects. A retained “online” message alone is insufficient. Charts use UTC capture time; allowable future clock skew is 2 seconds.</p></details>
  </main>
  <div v-else class="industrial-wait">Starting local telemetry receiver…</div>
</template>

<script>
export default {
  computed: {
    s() { return this.msg?.payload || null },
    sourceStatusIsCurrent() { return this.s?.broker_state === 'connected' && this.s?.gateway_state === 'online' },
    sourceStatusLabel() { const source = this.s?.source_state; return this.sourceStatusIsCurrent ? this.label(source) : ['healthy', 'error'].includes(source) ? 'Last known: ' + this.label(source) : 'Unknown' },
    sourceStatusTone() { return this.sourceStatusIsCurrent ? this.tone(this.s.source_state) : 'tone-muted' },
    readingCaption() { return this.s.measurement_state === 'no_data' ? 'No accepted measurement yet' : this.s.measurement_state === 'stale' ? 'STALE · Last valid reading' : this.s.source_state === 'error' ? 'Last valid reading · Source error' : 'Accepted sample · ' + this.time(this.s.last_sample.capture_utc) + ' UTC' },
    tempRange() { const v = (this.s.history || []).map(p => p.temperature_c); const lo = Math.min(...v), hi = Math.max(...v); return { min: Math.floor(lo - 1), max: Math.ceil(hi + 1) } }
  },
  methods: {
    label(v) { return String(v || 'unknown').replace(/_/g, ' ').replace(/^./, x => x.toUpperCase()) },
    number(v) { return typeof v === 'number' && Number.isFinite(v) ? v.toFixed(1) : '—' },
    utc(v) { const d = new Date(v); return Number.isNaN(d.getTime()) ? '—' : d.toISOString().replace('T', ' ').slice(0, 19) },
    time(v) { const d = new Date(v); return Number.isNaN(d.getTime()) ? '—' : d.toISOString().slice(11, 19) },
    tone(v) { return ['online', 'connected', 'healthy'].includes(v) ? 'tone-good' : ['offline', 'disconnected', 'error'].includes(v) ? 'tone-bad' : 'tone-muted' },
    pointY(value, key) { const min = key === 'humidity_pct' ? 0 : this.tempRange.min; const max = key === 'humidity_pct' ? 100 : this.tempRange.max; return 208 - ((value - min) / (max - min)) * 184 },
    points(key) { const h = this.s.history || []; const first = h[0].at_ms; const span = Math.max(1, h[h.length - 1].at_ms - first); return h.map(p => (48 + ((p.at_ms - first) / span) * 900).toFixed(2) + ',' + this.pointY(p[key], key).toFixed(2)).join(' ') }
  }
}
</script>

<style>
.industrial-console{--ink:#e8eff4;--muted:#92a4b3;--line:#283d4c;background:#101f2b;color:var(--ink);font-family:Inter,Segoe UI,Arial,sans-serif;padding:28px;border-radius:14px;max-width:1440px;margin:0 auto}.industrial-console *{box-sizing:border-box}.demo-banner{background:#3a3021;border:1px solid #806434;color:#f4cf83;padding:10px 14px;border-radius:7px;font-size:12px;font-weight:750;letter-spacing:1px;display:flex;align-items:center;gap:9px}.hardware-banner{background:#163c35;border-color:#367e69;color:#9fe0c7}.hardware-banner .demo-dot{background:#75d6af}.hardware-banner .demo-note{color:#a8cdbc}.demo-dot{height:7px;width:7px;background:#efbd65;border-radius:50%;display:inline-block}.demo-note{margin-left:auto;letter-spacing:0;font-weight:400;color:#d5bf96}.console-header{display:flex;justify-content:space-between;align-items:center;padding:30px 0 26px}.eyebrow{font-size:11px;letter-spacing:2px;color:#84a8b8;font-weight:700}.console-header h1{font-size:32px;line-height:1.2;font-weight:650;letter-spacing:-.8px;margin:9px 0}.console-header p{font-size:13px;color:var(--muted);margin:0}.header-status{text-align:right;display:grid;gap:12px}.header-status small{font-size:11px;color:var(--muted);font-variant-numeric:tabular-nums}.state-pill{border-radius:20px;padding:7px 15px;justify-self:end;font-size:12px;font-weight:700;letter-spacing:.4px;background:#2d3d49;color:#b7c7d1}.state-pill.fresh{background:#173f39;color:#81d5ba}.state-pill.stale{background:#4a3424;color:#f0bd81}.status-grid{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid var(--line);border-radius:9px;background:#142632;margin-bottom:22px}.status-cell{padding:17px 20px;display:flex;flex-direction:column;gap:8px;border-right:1px solid var(--line)}.status-cell:last-child{border-right:0}.status-cell>span,.detail-grid span{font-size:11px;color:var(--muted)}.status-cell strong{font-size:14px;font-weight:600}.tone-good{color:#7bd4b5}.tone-bad{color:#f2a591}.tone-muted{color:#b2bec8}.reading-grid{display:grid;grid-template-columns:1fr 1fr .85fr;gap:16px;margin-bottom:24px}.reading-card{background:#182b38;border:1px solid #304552;border-radius:9px;padding:22px}.reading-top{display:flex;align-items:center;gap:10px;font-size:13px;color:#bed0db}.sensor-mark{width:28px;height:28px;border-radius:7px;display:grid;place-items:center;font-size:12px;font-weight:800}.sensor-mark.temperature{background:#4d3923;color:#efbb70}.sensor-mark.humidity{background:#1d494a;color:#77d2cd}.register-tag{font-size:10px;color:#829ba9;margin-left:auto}.reading-value{font-size:57px;line-height:1.15;font-weight:600;letter-spacing:-2px;margin:24px 0 15px;font-variant-numeric:tabular-nums}.reading-value span{font-size:20px;color:#8ba4b3;letter-spacing:0;margin-left:9px}.reading-caption{font-size:11px;color:var(--muted)}.age-value{font-size:45px;margin-top:37px}.dimmed .reading-value{color:#b9b6b1}.fault-bar{display:flex;gap:12px;flex-wrap:wrap;padding:12px 15px;border:1px solid #77513e;background:#3c2d25;color:#e7b99b;font-size:12px;border-radius:7px;margin-bottom:18px}.fault-bar strong{color:#f3cfb4}.trend-panel{background:#142632;border:1px solid var(--line);border-radius:9px;padding:22px}.panel-heading{display:flex;justify-content:space-between;align-items:center;margin-bottom:22px}.panel-heading h2{font-size:15px;font-weight:600;margin:0 0 6px}.panel-heading p{font-size:11px;color:var(--muted);margin:0}.chart-legend{display:flex;gap:20px;font-size:11px;color:#c0cdd6}.chart-legend span:before{content:'';display:inline-block;width:15px;height:3px;margin-right:7px;vertical-align:middle}.temp-key:before{background:#e9ad56}.humidity-key:before{background:#50c7be}.chart-wrap svg{width:100%;height:230px;overflow:visible}.chart-grid line{stroke:#2a3d4b;stroke-width:1}.axis-labels{fill:#7d97a8;font-size:11px}.trend-temperature,.trend-humidity{fill:none;stroke-width:2.5;stroke-linejoin:round;vector-effect:non-scaling-stroke}.trend-temperature{stroke:#e9ad56}.trend-humidity{stroke:#50c7be}.chart-times{display:flex;justify-content:space-between;margin:8px 4.8% 0;color:#829eaf;font-size:10px;font-variant-numeric:tabular-nums}.chart-empty{height:250px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;color:#7894a5}.chart-empty strong{font-size:19px;font-weight:500;color:#a3b9c7}.chart-empty span{font-size:12px}.detail-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:20px 0}.detail-grid>div{display:flex;justify-content:space-between;border-bottom:1px solid var(--line);padding:12px 3px}.detail-grid strong{font-size:13px;color:#c9d6df;font-variant-numeric:tabular-nums}.console-footer{display:flex;gap:20px;justify-content:space-between;font-size:10px;color:#7e98aa;margin-top:23px;line-height:1.6}.console-footer>span:first-child{letter-spacing:1px}.clock-note{font-size:10px;color:#8098a9;margin-top:14px}.clock-note summary{cursor:pointer}.clock-note p{max-width:900px;line-height:1.6;margin-top:8px}.industrial-wait{padding:40px;color:#b5c4d0;background:#101f2b}@media(max-width:900px){.industrial-console{padding:18px}.reading-grid{grid-template-columns:1fr 1fr}.age-card{grid-column:1/-1}.age-card .reading-value{margin:15px 0}.status-grid{grid-template-columns:1fr 1fr}.status-cell:nth-child(2){border-right:0}.status-cell:nth-child(-n+2){border-bottom:1px solid var(--line)}.detail-grid{grid-template-columns:1fr 1fr}.demo-note{display:none}.console-header h1{font-size:26px}}@media(max-width:560px){.reading-grid{grid-template-columns:1fr}.age-card{grid-column:auto}.console-header{display:block}.header-status{text-align:left;display:flex;align-items:center;margin-top:20px}.panel-heading{display:block}.chart-legend{margin-top:14px}.reading-value{font-size:48px}.console-footer{display:block}.console-footer span{display:block;margin-top:6px}}
</style>
