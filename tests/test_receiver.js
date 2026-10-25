'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const receiver = require('../dashboard/receiver.js');
const NOW = Date.parse('2026-10-19T12:00:00.000Z');
const topic = 'industrial/gw-01/telemetry';
function sample(overrides = {}, now = NOW) {
    return { schema_version:1, device_id:'gw-01', source_mode:'simulated', boot_id:'boot-a', seq:1,
        slave_id:1, uptime_ms:1000, sample_ts_utc:new Date(now).toISOString(), time_valid:true,
        sample_age_ms:0, quality:'good', values:{temperature_c:0, humidity_pct:0}, error:null, ...overrides };
}
function deliver(s, p, now=NOW, extra={}) { return receiver.process(s,{kind:'mqtt',topic,payload:p,...extra},now); }
function setup() { const s=receiver.createState(); receiver.process(s,{kind:'broker',connected:true},NOW); return s; }

test('no data stays distinct from gateway state and zero is a valid reading', () => {
    const s=setup(); let v=receiver.snapshot(s,NOW);
    assert.equal(v.measurement_state,'no_data'); assert.equal(v.gateway_state,'unknown');
    v=deliver(s,sample()); assert.equal(v.values.temperature_c,0); assert.equal(v.values.humidity_pct,0);
    assert.equal(v.measurement_state,'fresh'); assert.equal(v.gateway_state,'online');
});
test('negative temperature accepted; all ticks preserve one chart point', () => {
    const s=setup(); deliver(s,sample({values:{temperature_c:-7.3,humidity_pct:48.1}}));
    for(let i=0;i<20;i++) receiver.process(s,{kind:'tick'},NOW+i*1000);
    const v=receiver.snapshot(s,NOW+20000);
    assert.equal(v.values.temperature_c,-7.3); assert.equal(v.history.length,1);
    assert.equal(v.measurement_state,'stale'); assert.equal(v.source_state,'healthy');
});
test('stale boundary is strictly over ten seconds without any message', () => {
    const s=setup(); deliver(s,sample());
    assert.equal(receiver.snapshot(s,NOW+10000).measurement_state,'fresh');
    assert.equal(receiver.snapshot(s,NOW+10001).measurement_state,'stale');
});
test('bad read preserves last good values and changes source health only', () => {
    const s=setup(); deliver(s,sample());
    const v=deliver(s,sample({seq:2,quality:'bad',values:null,error:'modbus_timeout',sample_ts_utc:null,time_valid:false,sample_age_ms:null}),NOW+2000);
    assert.equal(v.source_state,'error'); assert.equal(v.source_error,'modbus_timeout');
    assert.equal(v.gateway_state,'online'); assert.equal(v.measurement_state,'fresh');
    assert.equal(v.values.temperature_c,0); assert.equal(v.history.length,1); assert.equal(v.sample_age_ms,2000);
});
test('source recovery adds one fresh point and clears error', () => {
    const s=setup(); deliver(s,sample({quality:'bad',values:null,error:'timeout',sample_ts_utc:null,time_valid:false,sample_age_ms:null}));
    const v=deliver(s,sample({seq:2},NOW+2000),NOW+2000);
    assert.equal(v.source_state,'healthy'); assert.equal(v.source_error,null); assert.equal(v.history.length,1);
});
test('malformed and invalid data never become last-good readings', async t => {
    const cases = [
        ['JSON','{'], ['null',null], ['array',[]], ['missing fields',{}],
        ['NaN',sample({values:{temperature_c:NaN,humidity_pct:50}})],
        ['infinity',sample({values:{temperature_c:20,humidity_pct:Infinity}})],
        ['null numeric',sample({values:{temperature_c:null,humidity_pct:50}})],
        ['out of range humidity',sample({values:{temperature_c:20,humidity_pct:101}})],
        ['string numeric',sample({values:{temperature_c:'20',humidity_pct:50}})],
        ['missing sample age',sample({sample_age_ms:undefined})],
        ['negative sample age',sample({sample_age_ms:-1})],
        ['bad error values',sample({quality:'bad',error:'timeout'})],
        ['unknown schema',sample({schema_version:2})], ['wrong identity',sample({device_id:'other'})],
        ['invalid calendar day',sample({sample_ts_utc:'2026-02-31T12:00:00Z'})],
        ['missing verified timestamp',sample({sample_ts_utc:null})]
    ];
    for (const [name,p] of cases) await t.test(name, () => {
        const s=setup(), v=deliver(s,p);
        assert.equal(v.values,null); assert.equal(v.history.length,0); assert.equal(v.counters.rejected,1);
    });
});
test('delayed sample cannot become fresh even if publisher age claims zero', () => {
    const s=setup(); const v=deliver(s,sample({},NOW-10001));
    assert.equal(v.measurement_state,'no_data'); assert.equal(v.history.length,0);
    assert.equal(v.source_error,'sample_expired'); assert.equal(v.counters.expired,1);
});
test('publisher age is used conservatively', () => {
    const s=setup(); const v=deliver(s,sample({sample_age_ms:10001}));
    assert.equal(v.history.length,0); assert.equal(v.last_rejected.reason,'sample_expired');
});
test('future clock skew allows at most two seconds', () => {
    const s=setup(); let v=deliver(s,sample({},NOW+2001));
    assert.equal(v.values,null); assert.equal(v.last_rejected.reason,'capture_time_in_future');
    v=deliver(s,sample({},NOW+2000)); assert.equal(v.measurement_state,'fresh'); assert.equal(v.sample_age_ms,0);
});
test('unverified time is not granted verified fresh status', () => {
    const s=setup(); const v=deliver(s,sample({time_valid:false,sample_ts_utc:null,sample_age_ms:null}));
    assert.equal(v.measurement_state,'no_data'); assert.equal(v.source_error,'time_unverified'); assert.equal(v.history.length,0);
});
test('duplicate sequence and reordered sequence never add chart points', () => {
    const s=setup(); deliver(s,sample({seq:10}));
    let v=deliver(s,sample({seq:10},NOW+1000),NOW+1000);
    assert.equal(v.counters.duplicate,1); assert.equal(v.history.length,1);
    v=deliver(s,sample({seq:9},NOW+2000),NOW+2000);
    assert.equal(v.counters.reordered,1); assert.equal(v.history.length,1);
});
test('higher sequence with older capture time cannot replace latest reading', () => {
    const s=setup(); deliver(s,sample({seq:10}));
    const v=deliver(s,sample({seq:11},NOW-1),NOW+1);
    assert.equal(v.last_rejected.reason,'reordered_capture_time'); assert.equal(v.last_sample.seq,10);
});
test('newer boot accepted and retired boot replay rejected despite higher sequence', () => {
    const s=setup(); deliver(s,sample({seq:50}));
    let v=deliver(s,sample({boot_id:'boot-b',seq:0},NOW+2000),NOW+2000);
    assert.equal(v.last_sample.boot_id,'boot-b'); assert.equal(v.last_sample.seq,0);
    v=deliver(s,sample({boot_id:'boot-a',seq:99},NOW+4000),NOW+4000);
    assert.equal(v.last_sample.boot_id,'boot-b'); assert.equal(v.history.length,2); assert.equal(v.counters.replay,1);
});
test('unknown old boot and unproven bad boot cannot replace current session', () => {
    const s=setup(); deliver(s,sample());
    let v=deliver(s,sample({boot_id:'older-unknown'},NOW-1),NOW+1000);
    assert.equal(v.last_sample.boot_id,'boot-a'); assert.equal(v.last_rejected.reason,'unproven_new_session');
    v=deliver(s,sample({boot_id:'boot-b',quality:'bad',values:null,error:'timeout',time_valid:false,sample_ts_utc:null,sample_age_ms:null}),NOW+2000);
    assert.equal(s.activeBoot,'boot-a'); assert.equal(v.history.length,1);
});
test('retained online alone is unknown; broker loss overrides earlier online', () => {
    const s=setup(); let v=receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/availability',payload:'online',retain:true},NOW);
    assert.equal(v.gateway_state,'unknown');
    v=deliver(s,sample()); assert.equal(v.gateway_state,'online');
    v=receiver.process(s,{kind:'broker',connected:false},NOW+1); assert.equal(v.gateway_state,'unknown'); assert.equal(v.broker_state,'disconnected');
    receiver.process(s,{kind:'broker',connected:true},NOW+2);
    v=receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/availability',payload:'online',retain:true},NOW+3);
    assert.equal(v.gateway_state,'unknown');
    v=deliver(s,sample({seq:2},NOW+4),NOW+4); assert.equal(v.gateway_state,'online');
    v=receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/availability',payload:'offline',retain:true},NOW+5);
    assert.equal(v.gateway_state,'offline'); assert.equal(v.values.temperature_c,0);
});
test('retained telemetry and diagnostics cannot establish live gateway proof', () => {
    const s=setup(); let v=deliver(s,sample(),NOW,{retain:true});
    assert.equal(v.measurement_state,'no_data'); assert.equal(v.counters.replay,1); assert.equal(v.gateway_state,'unknown');
    v=receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/diagnostics',payload:'{"reads_ok":2}'},NOW);
    assert.equal(v.gateway_state,'unknown'); assert.equal(v.diagnostics.reads_ok,2);
});
test('chart memory is bounded at 120 accepted samples', () => {
    const s=setup(); let v;
    for(let i=0;i<200;i++) v=deliver(s,sample({seq:i},NOW+i*2000),NOW+i*2000);
    assert.equal(v.history.length,120); assert.equal(v.history[0].seq,80);
});
test('deployed transport function recognizes Node-RED status keys and visual status', () => {
    const flows=JSON.parse(fs.readFileSync(path.join(__dirname,'../dashboard/flows.json'),'utf8'));
    const code=flows.find(n => n.id === 'transport-event').func;
    const run=status => vm.runInNewContext('(function(msg){'+code+'})',{} )({status})._receiverEvent.connected;
    assert.equal(run({fill:'green',shape:'dot',text:'node-red:common.status.connected'}),true);
    assert.equal(run({text:'node-red:common.status.connected'}),true);
    assert.equal(run({text:'connected'}),true);
    assert.equal(run({fill:'green',shape:'dot',text:'verbunden'}),true);
    assert.equal(run({fill:'red',shape:'ring',text:'node-red:common.status.disconnected'}),false);
    assert.equal(run({fill:'yellow',shape:'ring',text:'node-red:common.status.connecting'}),false);
    assert.equal(run({text:'disconnected'}),false);
    assert.equal(run(undefined),false);
});

test('hardware run stays waiting on availability/diagnostics, bad reads and unverified time', () => {
    const s=receiver.createState({expectedSourceMode:'hardware',runId:'physical-run'});
    receiver.process(s,{kind:'broker',connected:true},NOW);
    receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/availability',payload:'online',retain:true},NOW);
    receiver.process(s,{kind:'mqtt',topic:'industrial/gw-01/diagnostics',payload:{source_mode:'hardware'}},NOW);
    let v=receiver.snapshot(s,NOW);
    assert.equal(v.hardware_link_accepted,false);
    assert.equal(v.banner,'WAITING · HARDWARE TELEMETRY');
    v=deliver(s,sample({source_mode:'hardware',boot_id:'a'.repeat(32),quality:'bad',values:null,error:'timeout',time_valid:false,sample_ts_utc:null,sample_age_ms:null}));
    assert.equal(v.hardware_link_accepted,false);
    v=deliver(s,sample({source_mode:'hardware',boot_id:'a'.repeat(32),seq:2,time_valid:false,sample_ts_utc:null,sample_age_ms:null}));
    assert.equal(v.hardware_link_accepted,false);
    assert.equal(v.measurement_state,'no_data');
});
test('fresh hardware measurement changes banner, preserves stale and source error semantics', () => {
    const s=receiver.createState({expectedSourceMode:'hardware',runId:'physical-run'});
    receiver.process(s,{kind:'broker',connected:true},NOW);
    let v=deliver(s,sample({source_mode:'hardware',boot_id:'a'.repeat(32),values:{temperature_c:26.0,humidity_pct:54.4}}));
    assert.equal(v.banner,'HARDWARE · ESP32 / RS485');
    assert.equal(v.hardware_link_accepted,true);
    assert.equal(v.run_id,'physical-run');
    v=deliver(s,sample({source_mode:'hardware',boot_id:'a'.repeat(32),seq:2,quality:'bad',values:null,error:'timeout',sample_ts_utc:null,sample_age_ms:null,time_valid:false}),NOW+2000);
    assert.equal(v.values.temperature_c,26.0);
    assert.equal(v.source_state,'error');
    assert.equal(receiver.snapshot(s,NOW+10001).measurement_state,'stale');
});
test('hardware run rejects synthetic telemetry before session or live proof changes', () => {
    const s=receiver.createState({expectedSourceMode:'hardware'});
    receiver.process(s,{kind:'broker',connected:true},NOW);
    const v=deliver(s,sample());
    assert.equal(v.last_rejected.reason,'source_mode_mismatch');
    assert.equal(v.gateway_state,'unknown');
    assert.equal(s.activeBoot,null);
    assert.equal(v.values,null);
});
test('a receiver cannot mix simulated and hardware points in one run', () => {
    const s=setup();
    deliver(s,sample());
    const v=deliver(s,sample({source_mode:'hardware',boot_id:'hardware-new'},NOW+2000),NOW+2000);
    assert.equal(v.last_rejected.reason,'mixed_source_mode');
    assert.equal(v.history.length,1);
    assert.equal(v.source_mode,'simulated');
});
test('fresh run state never inherits an old boot, values, history or counters', () => {
    const old=setup();deliver(old,sample({seq:900}));
    const fresh=receiver.createState({expectedSourceMode:'hardware',runId:'new-run'});
    const v=receiver.snapshot(fresh,NOW);
    assert.equal(fresh.activeBoot,null);
    assert.equal(fresh.maxSeq,-1);
    assert.equal(v.values,null);assert.equal(v.history.length,0);
    assert.equal(v.counters.good,0);
    assert.equal(v.banner,'WAITING · HARDWARE TELEMETRY');
});
test('generated receiver initialization clears memory with launch policy', () => {
    const flows=JSON.parse(fs.readFileSync(path.join(__dirname,'../dashboard/flows.json'),'utf8'));
    const code=flows.find(n=>n.id==='receiver').initialize;
    const saved={receiverState:{old:true}};
    const policy={expectedSourceMode:'hardware',runId:'init-run'};
    vm.runInNewContext(code,{global:{get:key=>key==='industrialReceiver'?receiver:policy},
        flow:{set:(key,value)=>{saved[key]=value}},Date});
    assert.equal(saved.receiverState.runId,'init-run');
    assert.equal(saved.receiverState.activeBoot,null);
    assert.equal(saved.receiverView.values,null);
});

test('hardware policy rejects placeholder boot identities without any live proof', () => {
    const s=receiver.createState({expectedSourceMode:'hardware'});
    receiver.process(s,{kind:'broker',connected:true},NOW);
    const v=deliver(s,sample({source_mode:'hardware',boot_id:'fixture'}));
    assert.equal(v.last_rejected.reason,'hardware_boot_id');
    assert.equal(v.hardware_link_accepted,false);
    assert.equal(v.gateway_state,'unknown');
});
