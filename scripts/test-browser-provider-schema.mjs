// Exercise the exact embedded launcher and MCP tools/list without connecting to Chrome.
import assert from 'node:assert/strict';
import {delimiter} from 'node:path';
import {fileURLToPath} from 'node:url';
import {providerBootstrapSource} from './browser-provider-source.mjs';
import {Client, StdioClientTransport} from '../node_modules/chrome-devtools-mcp/build/src/third_party/index.js';

const transport = new StdioClientTransport({
  command: process.execPath,
  args: ['--input-type=module', '--eval', providerBootstrapSource(), '--',
    '--page-id-routing', '--experimentalStructuredContent', '--no-usage-statistics'],
  env: {...process.env, PATH: fileURLToPath(new URL('../node_modules/.bin', import.meta.url)) + delimiter + process.env.PATH},
  stderr: 'pipe',
});
const client = new Client({name: 'peekaboo-schema-contract', version: '1.0.0'});
try {
  await client.connect(transport, {timeout: 10000});
  const result = await client.listTools({}, {timeout: 10000});
  const locator = result.tools.find(tool => tool.name === 'peekaboo_locator_action');
  const wait = result.tools.find(tool => tool.name === 'wait_for');
  assert.deepEqual(wait.inputSchema.properties.loadState.enum, ['domcontentloaded','load','networkidle']);
  assert.equal(wait.inputSchema.properties.url.anyOf[0].type, 'string');
  const network = result.tools.find(tool => tool.name === 'get_network_request');
  assert.deepEqual(network.inputSchema.properties.documentFormat.enum,['pdf','md','xlsx','csv','docx','pptx']);
  assert.equal(network.inputSchema.properties.assets.maxItems,16);
  assert.equal(network.inputSchema.properties.expectedURL.type,'string');
  const script = result.tools.find(tool => tool.name === 'evaluate_script');
  assert.ok(locator);
  assert.ok(script);
  const properties = locator.inputSchema.properties;
  assert.deepEqual(properties.action.enum, ['click', 'dblclick', 'fill', 'hover', 'type', 'press', 'check', 'uncheck', 'select', 'read', 'read-all', 'count', 'wait', 'paste', 'copy', 'clipboard-read', 'clipboard-write']);
  assert.equal(properties.items.maxItems,16);
  assert.equal(locator.inputSchema.required.includes('query'),false);
  assert.equal(properties.fields.maxItems, 12);
  assert.equal(properties.fields.items.type, 'string');
  assert.equal(properties.limit.maximum, 50);
  assert.equal(properties.offset.minimum, 0);
  const textQuery = properties.query.anyOf.find(query => query.required.includes('text'));
  assert.equal(textQuery.properties.exact.type, 'boolean');
  assert.equal(textQuery.additionalProperties, false);
  const roleQuery = properties.query.anyOf.find(query => query.required.includes('role'));
  assert.equal(roleQuery.properties.name.anyOf[0].type, 'string');
  assert.equal(roleQuery.properties.name.anyOf[1].properties.regex.type, 'string');
  assert.equal(roleQuery.additionalProperties, false);
  assert.ok(properties.query.anyOf[0].properties.has.anyOf);
  assert.ok(properties.query.anyOf[0].properties.hasNot.$ref || properties.query.anyOf[0].properties.hasNot.anyOf);
  assert.equal(properties.query.anyOf[0].properties.visible.type, 'boolean');
  assert.equal(properties.query.anyOf[0].properties.hasText.anyOf[0].type, 'string');
  assert.equal(properties.query.anyOf[0].properties.hasNotText.anyOf[0].type, 'string');
  assert.equal(properties.query.anyOf[0].properties.nth.minimum, -1);
  assert.deepEqual(properties.button.enum, ['left', 'right', 'middle']);
  assert.deepEqual(properties.modifiers.items.enum, ['Alt', 'Control', 'Meta', 'Shift', 'ControlOrMeta']);
  assert.ok(locator.inputSchema.required.includes('pageId'));
  assert.equal(script.inputSchema.properties.skipNavigationWait.type, 'boolean');
  assert.equal(script.inputSchema.properties.waitForStableDom.type, 'boolean');
  const upload = result.tools.find(tool => tool.name === 'upload_file');
  assert.ok(upload);
  // Keep the relevant real MCP Tool records for the opt-in Swift integration test.
  if (process.argv.includes('--json')) process.stdout.write(JSON.stringify([locator, script, wait, network, upload]));
  else console.log('Provider MCP tools/list schema contract passed; no browser connection requested.');
} finally {
  await client.close();
  await transport.close();
}
