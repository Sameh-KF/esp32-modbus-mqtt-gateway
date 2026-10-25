'use strict';

// Plain data state: safe for Node-RED's in-memory context and deterministic tests.
const STALE_MS = 10000;
const FUTURE_SKEW_MS = 2000;
const PREFIX = 'industrial/gw-01/';
const isObject = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const finite = x => typeof x === 'number' && Number.isFinite(x);
const integer = x => Number.isSafeInteger(x) && x >= 0;

function createState(options = {}) {
    const expectedSourceMode = options.expectedSourceMode ?? null;
    if (expectedSourceMode !== null && !['simulated', 'hardware'].includes(expectedSourceMode)) {
        throw new Error('Receiver source policy must be simulated, hardware or null');
    }
    return {
        expectedSourceMode, runId: options.runId || null,
        brokerConnected: false, brokerConnectedAt: null, gatewaySignal: 'unknown',
        lastLiveEvidenceAt: null, activeBoot: null, retiredBoots: [], maxSeq: -1,
        newestCaptureAt: null, sourceMode: 'unknown', sourceState: 'unknown',
        sourceError: null, lastGood: null, history: [], diagnostics: null,
        lastMessageAt: null, lastRejected: null,
        counters: { accepted: 0, good: 0, bad: 0, rejected: 0, duplicate: 0, reordered: 0, replay: 0, expired: 0 }
    };
}

function decode(raw) {
    if (Buffer.isBuffer(raw)) raw = raw.toString('utf8');
    if (typeof raw === 'string') return JSON.parse(raw);
    return raw;
}

function reject(state, reason, now, counter) {
    state.counters.rejected++;
    if (counter) state.counters[counter]++;
    state.lastRejected = { reason, at_utc: new Date(now).toISOString() };
    return snapshot(state, now);
}

function validate(p) {
    if (!isObject(p)) return 'payload_not_object';
    if (p.schema_version !== 1 || p.device_id !== 'gw-01') return 'identity_or_schema';
    if (!['simulated', 'hardware'].includes(p.source_mode)) return 'source_mode';
    if (typeof p.boot_id !== 'string' || !/^[A-Za-z0-9_.:-]{1,128}$/.test(p.boot_id)) return 'boot_id';
    if (!integer(p.seq) || !integer(p.uptime_ms)) return 'sequence_or_uptime';
    if (!Number.isInteger(p.slave_id) || p.slave_id < 1 || p.slave_id > 247) return 'slave_id';
    if (typeof p.time_valid !== 'boolean') return 'time_valid';
    if (p.sample_age_ms !== null && (!finite(p.sample_age_ms) || p.sample_age_ms < 0)) return 'sample_age';
    if (p.sample_ts_utc !== null && (typeof p.sample_ts_utc !== 'string' ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(p.sample_ts_utc) ||
        !Number.isFinite(Date.parse(p.sample_ts_utc)))) return 'capture_timestamp';
    if (p.sample_ts_utc !== null) {
        const canonical = p.sample_ts_utc.includes('.') ? p.sample_ts_utc.replace(/\.(\d{1,3})Z$/, (_, digits) => '.' + digits.padEnd(3, '0') + 'Z') : p.sample_ts_utc.replace('Z', '.000Z');
        if (new Date(p.sample_ts_utc).toISOString() !== canonical) return 'capture_timestamp';
    }
    if (p.quality === 'good') {
        if (!isObject(p.values) || !finite(p.values.temperature_c) || !finite(p.values.humidity_pct) ||
            p.values.humidity_pct < 0 || p.values.humidity_pct > 100 || p.error !== null) return 'good_values';
        if (p.time_valid && (p.sample_ts_utc === null || p.sample_age_ms === null)) return 'verified_time_missing';
    } else if (p.quality === 'bad') {
        if (p.values !== null || typeof p.error !== 'string' || p.error.length < 1 || p.error.length > 256) return 'bad_values';
    } else return 'quality';
    return null;
}

function process(state, event, now = Date.now()) {
    if (!Number.isFinite(now)) throw new Error('Receiver requires a finite UTC receiver clock');
    if (event.kind === 'tick') return snapshot(state, now);
    if (event.kind === 'broker') {
        const connected = event.connected === true;
        if (connected && !state.brokerConnected) {
            state.brokerConnectedAt = now;
            state.lastLiveEvidenceAt = null;
            state.gatewaySignal = 'unknown';
        }
        if (!connected) {
            state.gatewaySignal = 'unknown';
            state.lastLiveEvidenceAt = null;
        }
        state.brokerConnected = connected;
        return snapshot(state, now);
    }
    if (event.kind !== 'mqtt' || typeof event.topic !== 'string') return snapshot(state, now);
    const kind = event.topic.startsWith(PREFIX) ? event.topic.slice(PREFIX.length) : '';
    if (!['telemetry', 'availability', 'diagnostics'].includes(kind)) return snapshot(state, now);
    state.lastMessageAt = now;
    if (kind === 'availability') {
        const signal = Buffer.isBuffer(event.payload) ? event.payload.toString('utf8') : event.payload;
        if (!['online', 'offline'].includes(signal)) return reject(state, 'availability_payload', now);
        state.gatewaySignal = signal;
        return snapshot(state, now);
    }
    let p;
    try { p = decode(event.payload); } catch { return reject(state, 'invalid_json', now); }
    if (kind === 'diagnostics') {
        if (!isObject(p)) return reject(state, 'diagnostics_not_object', now);
        // Diagnostics are informational and cannot prove freshness or identity.
        // A valid non-retained telemetry message is required to confirm the gateway.
        state.diagnostics = p;
        return snapshot(state, now);
    }
    if (event.retain === true) return reject(state, 'retained_telemetry', now, 'replay');
    const issue = validate(p);
    if (issue) return reject(state, issue, now);
    if (state.expectedSourceMode && p.source_mode !== state.expectedSourceMode) {
        return reject(state, 'source_mode_mismatch', now);
    }
    if (state.expectedSourceMode === 'hardware' && !/^[0-9a-f]{32}$/.test(p.boot_id)) {
        return reject(state, 'hardware_boot_id', now);
    }
    if (state.sourceMode !== 'unknown' && p.source_mode !== state.sourceMode) {
        return reject(state, 'mixed_source_mode', now);
    }
    const captureAt = p.time_valid && p.sample_ts_utc !== null ? Date.parse(p.sample_ts_utc) : null;
    if (captureAt !== null && captureAt - now > FUTURE_SKEW_MS) {
        state.sourceState = 'error'; state.sourceError = 'capture_time_in_future';
        return reject(state, 'capture_time_in_future', now);
    }
    if (state.retiredBoots.includes(p.boot_id)) return reject(state, 'retired_session', now, 'replay');
    if (state.activeBoot !== null && state.activeBoot !== p.boot_id) {
        if (p.quality !== 'good' || captureAt === null ||
            (state.newestCaptureAt !== null && captureAt <= state.newestCaptureAt)) {
            return reject(state, 'unproven_new_session', now, 'replay');
        }
        state.retiredBoots.push(state.activeBoot);
        if (state.retiredBoots.length > 64) state.retiredBoots.shift();
        state.maxSeq = -1;
    }
    state.activeBoot = p.boot_id;
    if (p.seq === state.maxSeq) return reject(state, 'duplicate_sequence', now, 'duplicate');
    if (p.seq < state.maxSeq) return reject(state, 'reordered_sequence', now, 'reordered');
    if (p.quality === 'good' && captureAt !== null && state.newestCaptureAt !== null && captureAt < state.newestCaptureAt) {
        return reject(state, 'reordered_capture_time', now, 'reordered');
    }
    state.maxSeq = p.seq;
    state.lastLiveEvidenceAt = now;
    state.sourceMode = p.source_mode;
    state.counters.accepted++;
    if (p.quality === 'bad') {
        state.counters.bad++; state.sourceState = 'error'; state.sourceError = p.error;
        return snapshot(state, now);
    }
    if (captureAt === null) {
        state.sourceState = 'error'; state.sourceError = 'time_unverified';
        return reject(state, 'time_unverified', now);
    }
    // Use the older of UTC capture time and publisher-reported age, conservatively.
    const effectiveCaptureAt = Math.min(captureAt, now - p.sample_age_ms);
    state.newestCaptureAt = captureAt;
    if (now - effectiveCaptureAt > STALE_MS) {
        state.sourceState = 'error'; state.sourceError = 'sample_expired';
        return reject(state, 'sample_expired', now, 'expired');
    }
    state.counters.good++; state.sourceState = 'healthy'; state.sourceError = null;
    state.lastGood = { temperature_c: p.values.temperature_c, humidity_pct: p.values.humidity_pct,
        capture_at_ms: effectiveCaptureAt, capture_utc: p.sample_ts_utc, received_at_ms: now,
        boot_id: p.boot_id, seq: p.seq, source_mode: p.source_mode };
    state.history.push({ at_ms: effectiveCaptureAt, temperature_c: p.values.temperature_c,
        humidity_pct: p.values.humidity_pct, boot_id: p.boot_id, seq: p.seq });
    if (state.history.length > 120) state.history.shift();
    return snapshot(state, now);
}

function snapshot(state, now = Date.now()) {
    const age = state.lastGood ? Math.max(0, now - state.lastGood.capture_at_ms) : null;
    const liveEvidence = state.lastLiveEvidenceAt !== null && state.brokerConnectedAt !== null &&
        state.lastLiveEvidenceAt >= state.brokerConnectedAt;
    const gateway = !state.brokerConnected ? 'unknown' : state.gatewaySignal === 'offline' ? 'offline' :
        liveEvidence ? 'online' : 'unknown';
    const hardwareAccepted = state.lastGood?.source_mode === 'hardware';
    const waitingHardware = state.expectedSourceMode === 'hardware' && !hardwareAccepted;
    return {
        schema_version: 1, device_id: 'gw-01',
        run_id: state.runId, expected_source_mode: state.expectedSourceMode,
        hardware_link_accepted: hardwareAccepted,
        banner: hardwareAccepted ? 'HARDWARE · ESP32 / RS485' : waitingHardware ? 'WAITING · HARDWARE TELEMETRY' : 'SIMULATED · HOST TEST',
        validation_scope: hardwareAccepted ? 'Live ESP32-S3 / Modbus RTU monitoring.' :
            waitingHardware ? 'Waiting for live ESP32-S3 telemetry.' :
            'Simulation mode · host software test.',
        receiver_clock_assumption: state.expectedSourceMode === 'hardware' || hardwareAccepted ?
            'Freshness uses capture UTC and sample age; the ESP32 clock must be synchronized.' :
            'Publisher and receiver use the same computer clock in simulation mode.',
        receiver_ts_utc: new Date(now).toISOString(), stale_after_ms: STALE_MS, future_skew_ms: FUTURE_SKEW_MS,
        broker_state: state.brokerConnected ? 'connected' : 'disconnected', gateway_state: gateway,
        source_state: state.sourceState, source_mode: state.sourceMode, source_error: state.sourceError,
        measurement_state: age === null ? 'no_data' : age > STALE_MS ? 'stale' : 'fresh',
        sample_age_ms: age, values: state.lastGood ? {
            temperature_c: state.lastGood.temperature_c, humidity_pct: state.lastGood.humidity_pct
        } : null,
        last_sample: state.lastGood ? { capture_utc: state.lastGood.capture_utc,
            boot_id: state.lastGood.boot_id, seq: state.lastGood.seq, source_mode: state.lastGood.source_mode } : null,
        history: state.history.map(x => ({ ...x })), diagnostics: state.diagnostics,
        last_rejected: state.lastRejected, counters: { ...state.counters }
    };
}

module.exports = { createState, process, snapshot, validate, STALE_MS, FUTURE_SKEW_MS };
