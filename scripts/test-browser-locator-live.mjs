// Opt-in integration test: launches a temporary headless Chrome profile and local HTTP fixtures.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {delimiter} from 'node:path';
import {fileURLToPath} from 'node:url';
import {providerBootstrapSource} from './browser-provider-source.mjs';

const executablePath = process.env.PEEKABOO_TEST_CHROME;
assert.ok(executablePath, 'Set PEEKABOO_TEST_CHROME to an installed Chrome executable');
const originalPath = process.env.PATH;
process.env.PATH = fileURLToPath(new URL('../node_modules/.bin', import.meta.url)) + delimiter + originalPath;
await import('data:text/javascript,' + encodeURIComponent(providerBootstrapSource().split('process.argv =')[0]));
process.env.PATH = originalPath;
const {McpServer} = await import('../node_modules/chrome-devtools-mcp/build/src/index.js');
const {closeBrowser} = await import('../node_modules/chrome-devtools-mcp/build/src/browser.js');
const {mcpOptions} = await import('../node_modules/chrome-devtools-mcp/build/src/config/mcp-options.js');
const defaults = Object.fromEntries(Object.entries(mcpOptions).map(([key, option]) => [key, option.default]));

const child = createServer((_req, res) => res.end(`<!doctype html><div id="host"></div><script>
const root=document.querySelector('#host').attachShadow({mode:'open'});
root.innerHTML='<label>Name<input data-testid="name"></label><button data-testid="save">Save</button>';
let clicks=0;const inputs=[];let hovered=false;let inputClicks=0;const keys=[];
root.querySelector('input').addEventListener('keydown',e=>keys.push({key:e.key,shift:e.shiftKey,trusted:e.isTrusted}));
root.querySelector('input').addEventListener('click',()=>inputClicks++);
root.querySelector('input').addEventListener('input',e=>inputs.push(e.isTrusted));
root.querySelector('button').addEventListener('pointerenter',e=>hovered=e.isTrusted);
root.querySelector('button').addEventListener('click',e=>{parent.postMessage({value:root.querySelector('input').value,clicks:++clicks,trusted:e.isTrusted,inputs,hovered,inputClicks,keys},'*');if(clicks===1)root.querySelector('input').setSelectionRange(1,2);if(clicks===2)root.querySelector('input').disabled=true;});
for(const text of ['Ada inactive','Ada active','Grace active']){
 const button=document.createElement('button');button.className='refined';button.textContent=text;
 button.addEventListener('click',e=>parent.postMessage({kind:'refined',picked:text,trusted:e.isTrusted},'*'));root.append(button);
}
const controls=document.createElement('template');controls.innerHTML='<label>Choice<input type="checkbox" data-testid="choice"></label><input type="checkbox" data-testid="mixed"><input type="checkbox" data-testid="disabled" disabled><input type="radio" data-testid="radio"><div role="switch" aria-checked="false" tabindex="0" data-testid="switch">Switch</div>';root.append(controls.content);
root.querySelector('[data-testid="mixed"]').indeterminate=true;
window.addEventListener('message',e=>{if(e.data==='add-late')setTimeout(()=>{
  const input=document.createElement('input');input.dataset.testid='late';
  input.addEventListener('input',e=>parent.postMessage({kind:'late',value:input.value,trusted:e.isTrusted},'*'));
  root.append(input);
},600)});
const double=document.createElement('button');double.dataset.testid='double';double.textContent='Open editor';root.append(double);
const doubleEvents=[];
for(const type of ['click','dblclick'])double.addEventListener(type,e=>{
  doubleEvents.push({type:e.type,detail:e.detail,trusted:e.isTrusted});
  if(e.type==='dblclick')parent.postMessage({kind:'double',events:doubleEvents},'*');
});
const modified=document.createElement('button');modified.dataset.testid='modified';modified.textContent='Modified click';root.append(modified);
const modifiedEvents=[];
modified.addEventListener('contextmenu',e=>e.preventDefault());
modified.addEventListener('mouseup',e=>{
  modifiedEvents.push({button:e.button,alt:e.altKey,shift:e.shiftKey,control:e.ctrlKey,meta:e.metaKey,trusted:e.isTrusted});
  parent.postMessage({kind:'modified',events:modifiedEvents},'*');
});
const selects=document.createElement('template');selects.innerHTML='<label>Language<select data-testid="language"><option value="en">English</option><option value="fr">French</option><option value="x" disabled>Disabled</option></select></label><select multiple data-testid="languages"><option value="en">English</option><option value="fr">French</option></select>';root.append(selects.content);
const selectionEvents=[];
for(const select of root.querySelectorAll('select'))for(const type of ['input','change'])select.addEventListener(type,e=>{
  selectionEvents.push({id:select.dataset.testid,type:e.type,trusted:e.isTrusted,values:[...select.selectedOptions].map(option=>option.value)});
  parent.postMessage({kind:'selection',events:selectionEvents},'*');
});
const checkEvents=[];
for(const node of root.querySelectorAll('[type="checkbox"],[type="radio"],[role="switch"]'))node.addEventListener('click',e=>{
  if(node.getAttribute('role')==='switch')node.setAttribute('aria-checked',String(node.getAttribute('aria-checked')!=='true'));
  checkEvents.push({id:node.dataset.testid,checked:node.checked??(node.getAttribute('aria-checked')==='true'),trusted:e.isTrusted});
  parent.postMessage({kind:'check',events:checkEvents},'*');
});

</script>`));
await new Promise(resolve => child.listen(0, '127.0.0.1', resolve));
const childURL = `http://127.0.0.1:${child.address().port}`;
const parent = createServer((_req, res) => res.end(`<!doctype html><title>Locator input fixture</title>
<button class="ambiguous" onclick="window.outsideClicks++">Duplicate</button>
<button class="ambiguous" onclick="window.outsideClicks++">Duplicate</button>
<button data-testid="save" aria-label="Outside accessible">Outside</button><button hidden aria-label="Outside accessible">Hidden duplicate</button><iframe id="child" src="${childURL}"></iframe><pre id="result"></pre><pre id="checkResult"></pre><pre id="lateResult"></pre><pre id="doubleResult"></pre><pre id="modifiedResult"></pre><pre id="selectionResult"></pre>
<script>window.outsideClicks=0;window.refined=[];window.addEventListener('message',e=>{if(e.origin===${JSON.stringify(childURL)}&&e.data.kind==='refined'){window.refined.push(e.data);return;}if(e.origin===${JSON.stringify(childURL)})document.querySelector(e.data.kind==='selection'?'#selectionResult':e.data.kind==='modified'?'#modifiedResult':e.data.kind==='double'?'#doubleResult':e.data.kind==='check'?'#checkResult':e.data.kind==='late'?'#lateResult':'#result').textContent=JSON.stringify(e.data)})</script>`));
await new Promise(resolve => parent.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${parent.address().port}`;
let server;
try {
  server = await McpServer.from({...defaults, executablePath, headless: true, isolated: true,
    usageStatistics: false, performanceCrux: false, pageIdRouting: true, experimentalStructuredContent: true});
  const call = async (name, args) => {
    const result = await server.server._registeredTools[name].handler(args);
    assert.notEqual(result.isError, true, JSON.stringify(result));
    return result.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
  };
  const opened = await call('new_page', {url});
  const pageLine = opened.split('\n').find(line => line.includes(url) && /^\d+:/.test(line));
  assert.ok(pageLine, opened);
  const pageId = Number(pageLine.match(/^(\d+):/)[1]);
  const within = [{frame: {css: '#child'}}, {shadow: {css: '#host'}}];
  await call('peekaboo_locator_action', {pageId, query: {role: 'button', name: 'Outside accessible'}, action: 'hover'});
  const roleAmbiguous = await server.server._registeredTools.peekaboo_locator_action.handler({
    pageId, query: {role: 'button', name: 'Duplicate'}, action: 'click'});
  assert.equal(roleAmbiguous.isError, true);
  assert.match(JSON.stringify(roleAmbiguous), /exactly one match; found 2/);

  const everySnapshot = process.env.PEEKABOO_LOCATOR_EVERY_SNAPSHOT === '1';
  const started = performance.now();
  const filled = await call('peekaboo_locator_action', {pageId, within, query: {role: 'textbox', name: 'Name'}, action: 'fill', value: 'Ada 😀', includeSnapshot: everySnapshot});
  const hovered = await call('peekaboo_locator_action', {pageId, within, query: {role: 'button', name: 'Save'}, action: 'hover', includeSnapshot: everySnapshot});
  const clicked = await call('peekaboo_locator_action', {pageId, within, query: {testId: 'save'}, action: 'click', includeSnapshot: true});
  const actionMs = Math.round(performance.now() - started);
  assert.match(clicked, /uid=/, 'input should return fresh snapshot evidence');
  const read = await call('evaluate_script', {pageId, function: '()=>JSON.parse(document.querySelector("#result").textContent)', waitForStableDom: false});
  const result = JSON.parse(read.match(/```json\n([\s\S]*?)\n```/)[1]);
  assert.equal(result.value, 'Ada 😀');
  assert.equal(result.clicks, 1);
  assert.equal(result.trusted, true);
  assert.equal(result.hovered, true);
  assert.ok(result.inputs.length > 0 && result.inputs.every(value => value === true));
  await call('peekaboo_locator_action', {pageId, within, query: {label: 'Name'}, action: 'press', key: 'ArrowRight'});
  await call('peekaboo_locator_action', {pageId, within, query: {label: 'Name'}, action: 'press', key: 'Shift+ArrowLeft'});
  await call('peekaboo_locator_action', {pageId, within, query: {label: 'Name'}, action: 'type', value: '😀'});
  await call('peekaboo_locator_action', {pageId, within, query: {testId: 'save'}, action: 'click'});
  const typedRead = await call('evaluate_script', {pageId, function: '()=>JSON.parse(document.querySelector("#result").textContent)', waitForStableDom: false});
  const typed = JSON.parse(typedRead.match(/```json\n([\s\S]*?)\n```/)[1]);
  assert.equal(typed.value, 'A😀a 😀');
  assert.equal(typed.inputClicks, 0);
  assert.ok(typed.keys.some(event => event.key === 'ArrowLeft' && event.shift && event.trusted));
  assert.ok(typed.keys.every(event => event.trusted));
  assert.ok(typed.inputs.every(value => value === true));
  const disabled = await server.server._registeredTools.peekaboo_locator_action.handler({
    pageId, within, query: {label: 'Name'}, action: 'type', value: 'must not type',
  });
  assert.equal(disabled.isError, true);
  assert.match(JSON.stringify(disabled), /enabled editable/);
  for (const action of ['check', 'check', 'uncheck', 'uncheck']) {
    await call('peekaboo_locator_action', {pageId, within, query: {testId: 'choice'}, action});
  }
  await call('peekaboo_locator_action', {pageId, within, query: {testId: 'mixed'}, action: 'uncheck'});
  for (const action of ['check', 'uncheck']) {
    await call('peekaboo_locator_action', {pageId, within, query: {testId: 'switch'}, action});
  }
  await call('peekaboo_locator_action', {pageId, within, query: {testId: 'radio'}, action: 'check'});
  for (const [id, action, expected] of [['disabled', 'check', /disabled/], ['radio', 'uncheck', /Cannot uncheck/]]) {
    const rejected = await server.server._registeredTools.peekaboo_locator_action.handler({pageId, within, query: {testId: id}, action});
    assert.equal(rejected.isError, true);
    assert.match(JSON.stringify(rejected), expected);
  }
  const checksRead = await call('evaluate_script', {pageId,
    function: '()=>JSON.parse(document.querySelector("#checkResult").textContent)', waitForStableDom: false});
  const checkEvents = JSON.parse(checksRead.match(/```json\n([\s\S]*?)\n```/)[1]).events;
  assert.deepEqual(checkEvents.map(({id, checked}) => [id, checked]), [
    ['choice', true], ['choice', false], ['mixed', true], ['mixed', false],
    ['switch', true], ['switch', false], ['radio', true],
  ]);
  assert.ok(checkEvents.every(event => event.trusted));
  await call('evaluate_script', {pageId, function: '()=>{document.querySelector("#child").contentWindow.postMessage("add-late","*");return true}', waitForStableDom: false});
  await call('peekaboo_locator_action', {pageId, within, query: {testId: 'late'}, action: 'fill', value: 'Arrived', timeout: 2000});
  const lateRead = await call('evaluate_script', {pageId,
    function: '()=>JSON.parse(document.querySelector("#lateResult").textContent)', waitForStableDom: false});
  assert.deepEqual(JSON.parse(lateRead.match(/```json\n([\s\S]*?)\n```/)[1]), {kind: 'late', value: 'Arrived', trusted: true});
  await call('peekaboo_locator_action', {pageId, within, query: {testId: 'double'}, action: 'dblclick'});
  const doubleRead = await call('evaluate_script', {pageId,
    function: '()=>JSON.parse(document.querySelector("#doubleResult").textContent)', waitForStableDom: false});
  assert.deepEqual(JSON.parse(doubleRead.match(/```json\n([\s\S]*?)\n```/)[1]).events, [
    {type: 'click', detail: 1, trusted: true},
    {type: 'click', detail: 2, trusted: true},
    {type: 'dblclick', detail: 2, trusted: true},
  ]);
  for (const options of [{button: 'right', modifiers: ['Alt']}, {button: 'middle', modifiers: ['Shift']},
    {modifiers: ['ControlOrMeta']}, {}]) {
    await call('peekaboo_locator_action', {pageId, within, query: {testId: 'modified'}, action: 'click', ...options});
  }
  const modifiedRead = await call('evaluate_script', {pageId,
    function: '()=>JSON.parse(document.querySelector("#modifiedResult").textContent)', waitForStableDom: false});
  const normal = {button: 0, alt: false, shift: false, control: false, meta: false, trusted: true};
  assert.deepEqual(JSON.parse(modifiedRead.match(/```json\n([\s\S]*?)\n```/)[1]).events, [
    {...normal, button: 2, alt: true}, {...normal, button: 1, shift: true},
    {...normal, [process.platform === 'darwin' ? 'meta' : 'control']: true}, normal,
  ]);
  for (const [query, options] of [[{label: 'Language'}, {label: 'French'}],
    [{label: 'Language'}, {index: 0}], [{testId: 'languages'}, ['en', {label: 'French'}]],
    [{testId: 'languages'}, []]]) {
    await call('peekaboo_locator_action', {pageId, within, query, action: 'select', options});
  }
  const readSelections = async () => {
    const text = await call('evaluate_script', {pageId,
      function: '()=>JSON.parse(document.querySelector("#selectionResult").textContent)', waitForStableDom: false});
    return JSON.parse(text.match(/```json\n([\s\S]*?)\n```/)[1]).events;
  };
  const selectionEvents = await readSelections();
  assert.deepEqual(selectionEvents, [
    ...['input', 'change'].map(type => ({id: 'language', type, trusted: false, values: ['fr']})),
    ...['input', 'change'].map(type => ({id: 'language', type, trusted: false, values: ['en']})),
    ...['input', 'change'].map(type => ({id: 'languages', type, trusted: false, values: ['en', 'fr']})),
    ...['input', 'change'].map(type => ({id: 'languages', type, trusted: false, values: []})),
  ]);
  for (const options of ['x', ['en', 'fr'], [{index: 0}, {label: 'English'}], 'missing']) {
    const rejected = await server.server._registeredTools.peekaboo_locator_action.handler({
      pageId, within, query: {label: 'Language'}, action: 'select', options});
    assert.equal(rejected.isError, true);
  }
  assert.deepEqual(await readSelections(), selectionEvents, 'rejected selections must not emit events');
  const absent = await server.server._registeredTools.peekaboo_locator_action.handler({pageId, within,
    query: {testId: 'never-created'}, action: 'click', timeout: 100});
  assert.equal(absent.isError, true);
  assert.match(JSON.stringify(absent), /presence wait timed out/);
  const refused = await server.server._registeredTools.peekaboo_locator_action.handler({
    pageId, query: {css: '.ambiguous'}, action: 'click',
  });
  assert.equal(refused.isError, true);
  assert.match(JSON.stringify(refused), /exactly one match/);
  const after = await call('evaluate_script', {pageId,
    function: '()=>({outsideClicks:window.outsideClicks,inside:JSON.parse(document.querySelector("#result").textContent).clicks})',
    waitForStableDom: false});
  assert.deepEqual(JSON.parse(after.match(/```json\n([\s\S]*?)\n```/)[1]), {outsideClicks: 0, inside: 2});
  for (const query of [
    {css: '.refined', hasText: 'ADA', hasNotText: 'inactive'},
    {css: '.refined', hasText: 'active', hasNotText: 'inactive', nth: 1},
    {role: 'button', hasText: 'active', hasNotText: 'inactive', nth: -1},
  ]) await call('peekaboo_locator_action', {pageId, within, query, action: 'click'});
  const refined = await call('evaluate_script', {pageId, function: '()=>window.refined', waitForStableDom: false});
  assert.deepEqual(JSON.parse(refined.match(/```json\n([\s\S]*?)\n```/)[1]),
    ['Ada active', 'Grace active', 'Grace active'].map(picked => ({kind: 'refined', picked, trusted: true})));
  console.log(JSON.stringify({filteredOccurrencesVerified: true, computedRoleNamesVerified: true, crossOriginFrame: true, openShadowRoot: true, ambiguousRefusedWithoutInput: true,
    selectionPreservedByType: true, trustedLocatorKeyPress: true, trustedDoubleClick: true, locatorSelectionsVerified: true, modifiedButtonsVerified: true, modifiersReleased: true, checkedTransitionsVerified: true, delayedLocatorWait: true, absentLocatorTimedOut: true, checkedEvents: checkEvents.length, typeInputClicks: typed.inputClicks, disabledTypeRefused: true,
    requestedSnapshots: everySnapshot ? 3 : 1, actionMs,
    actionResponseCharacters: filled.length + hovered.length + clicked.length, ...result}));
} finally {
  await server?.close();
  await closeBrowser();
  await Promise.all([parent, child].map(server => new Promise(resolve => server.close(resolve))));
}
