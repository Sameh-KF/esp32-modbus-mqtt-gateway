'use strict';
const path = require('node:path');

module.exports = {
    uiHost: '127.0.0.1',
    uiPort: 1880,
    flowFile: path.join(__dirname, 'flows.json'),
    flowFilePretty: true,
    functionGlobalContext: {
        industrialReceiver: require(path.join(__dirname, 'receiver.js')),
        industrialRuntime: {
            expectedSourceMode: process.env.INDUSTRIAL_SOURCE_MODE === 'hardware' ? 'hardware' : 'simulated',
            runId: process.env.INDUSTRIAL_RUN_ID || null
        }
    },
    contextStorage: { default: { module: 'memory' } },
    functionExternalModules: false,
    telemetry: { enabled: false },
    logging: { console: { level: 'info', metrics: false, audit: false } },
    editorTheme: { projects: { enabled: false } }
};
