import assert from 'node:assert/strict';
import {locatorSource} from './browser-provider-source.mjs';
import {test} from 'node:test';
import {EventEmitter} from 'node:events';

const source = locatorSource();
const {withLocator, createLocatorTool, withExpectedNavigation, withExpectedDownload, createBrowserClipboardStore} = await import('data:text/javascript,' + encodeURIComponent(source));
const {parseKey} = await import('../node_modules/chrome-devtools-mcp/build/src/utils/keyboard.js');
const {zod} = await import('../node_modules/chrome-devtools-mcp/build/src/third_party/index.js');

function fixture() {
  const handles = [];
  const inputs = [];
  const dom = (children = {}) => ({isConnected: true, querySelectorAll: selector => children[selector] ?? []});
  const button = {...dom(), tagName: 'BUTTON', isContentEditable: true, matches: () => false};
  button.getRootNode = () => ({activeElement: button});
  const inner = dom({button: [button]});
  const frameElement = {...dom(), tagName: 'IFRAME', frameDocument: inner};
  const shadow = dom({iframe: [frameElement]});
  const host = {...dom(), tagName: 'DIV', shadowRoot: shadow};
  const document = dom({'#host': [host], button: [button]});
  const handle = node => {
    const result = {
      node, released: false,
      id: 'fixture-root',
      frame: {_id: 'fixture-frame'},
      client: {async send(method, params) {
        if (method === 'Accessibility.getFullAXTree') {
          assert.deepEqual(params, {frameId: 'fixture-frame'});
          return {nodes: node.axNodes ?? []};
        }
        assert.equal(method, 'Accessibility.queryAXTree');
        assert.deepEqual(params, {objectId: 'fixture-root', role: 'button'});
        return {nodes: node.axNodes ?? []};
      }},
      realm: {async adoptBackendNode(id) { return handle(node.backendNodes[id]); }},
      asElement() { return this; },
      async *queryAXTree(name, role) {
        const matches = node.axQuery ? node.axQuery(name, role) : node.axMatches ?? [];
        for (const match of matches) yield handle(match);
      },
      async evaluateHandle(fn, ...args) { return handle(fn(node, ...args.map(arg => arg?.node ?? arg))); },
      async evaluate(fn, ...args) { return fn(node, ...args.map(arg => arg?.node ?? arg)); },
      async contentFrame() { return node.frameDocument ? frame(node.frameDocument) : null; },
      async focus() { inputs.push(['focus']); },
      async type(value) { inputs.push(['type', value]); },
      asLocator() { return {
        setTimeout(value) { assert.ok(value > 0 && value <= 1000); return this; },
        async click(options) { inputs.push(options ? ['click', options] : ['click']); node.onClick?.(); },
        async fill(value) { inputs.push(['fill', value]); },
        async hover() { inputs.push(['hover']); },
      }; },
      async dispose() { assert.equal(this.released, false); this.released = true; },
    };
    handles.push(result);
    return result;
  };
  const frame = document => ({async evaluateHandle() { return handle(document); }});
  return {page: {pptrPage: {mainFrame: () => frame(document)},
    async waitForEventsAfterAction(action) { await action(); return {completed: true}; }},
    handles, inputs, button, host, frameElement, document};
}

test('withLocator resolves nested shadow/frame contexts and holds handles through the operation', async () => {
  const f = fixture();
  const result = await withLocator(f.page, {within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}], query: {css: 'button'}}, async handle => {
    assert.equal(handle.node, f.button);
    assert.ok(f.handles.every(item => !item.released));
    return 'completed';
  });
  assert.equal(result, 'completed');
  assert.ok(f.handles.every(item => item.released));
});

test('withLocator rejects ambiguous or detached scopes before invoking the operation', async () => {
  for (const detached of [false, true]) {
    const f = fixture();
    if (detached) f.button.isConnected = false;
    else f.document.querySelectorAll = () => [f.button, f.button];
    let called = false;
    await assert.rejects(withLocator(f.page, {query: {css: 'button'}}, () => { called = true; }),
      detached ? /detached/ : /exactly one/);
    assert.equal(called, false);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('withLocator releases all handles after operation failure without replaying it', async () => {
  const f = fixture();
  let attempts = 0;
  await assert.rejects(withLocator(f.page, {query: {css: 'button'}}, () => {
    attempts++;
    throw new Error('input failed');
  }), /input failed/);
  assert.equal(attempts, 1);
  assert.ok(f.handles.every(item => item.released));
});

test('withLocator fails if a selected iframe becomes unavailable', async () => {
  const f = fixture();
  delete f.frameElement.frameDocument;
  await assert.rejects(withLocator(f.page, {within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}], query: {css: 'button'}}, () => {
    throw new Error('must not dispatch');
  }), /Frame locator is unavailable/);
  assert.ok(f.handles.every(item => item.released));
});

test('createLocatorTool validates query and resource bounds with the pinned provider schema', () => {
  const tool = createLocatorTool({zod, parseKey});
  const schema = zod.object(tool.schema);
  const base = {query: {css: 'button'}, action: 'click'};
  assert.equal(schema.safeParse(base).success, true);
  for (const bad of [
    {...base, query: {css: 'button', label: 'Save'}},
    {...base, query: {script: 'return document.body'}},
    {...base, within: Array(9).fill({css: 'div'})},
    {...base, timeout: 0}, {...base, action: 'eval'},
  ]) assert.equal(schema.safeParse(bad).success, false);
  assert.equal(tool.pageScoped, true);
  assert.equal(tool.annotations.readOnlyHint, false);
});

test('createLocatorTool delegates click, fill and hover to trusted locators and returns snapshots', async () => {
  for (const action of ['click', 'dblclick', 'fill', 'hover', 'type']) {
    const f = fixture();
    const tool = createLocatorTool({zod, parseKey});
    const params = {query: {css: 'button'}, action, timeout: 1000, includeSnapshot: true};
    if (['fill', 'type'].includes(action)) params.value = 'Ada';
    let snapshots = 0;
    await tool.handler({page: f.page, params}, {
      appendResponseLine(text) { assert.match(text, /completed/); },
      attachWaitForResult(result) { assert.equal(result.completed, true); },
      includeSnapshot() { snapshots++; },
    });
    assert.deepEqual(f.inputs, action === 'type' ? [['focus'], ['type', 'Ada']] :
      [action === 'fill' ? ['fill', 'Ada'] : action === 'dblclick' ? ['click', {count: 2}] : [action]]);
    assert.equal(snapshots, 1);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('createLocatorTool rejects missing or extraneous values before resolving the page', async () => {
  for (const params of [{query: {css: 'input'}, action: 'fill'},
    {query: {css: 'input'}, action: 'type'},
    {query: {css: 'button'}, action: 'click', value: 'unexpected'}]) {
    const f = fixture();
    await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page, params}, {}), /Only fill and type require/);
    assert.equal(f.handles.length, 0);
    assert.equal(f.inputs.length, 0);
  }
});

test('createLocatorTool refuses noneditable and unfocusable typing targets without sending keys', async () => {
  for (const failure of ['disabled', 'readonly', 'noneditable', 'focus']) {
    const f = fixture();
    if (failure === 'disabled') f.button.matches = () => true;
    if (failure === 'readonly') f.button.readOnly = true;
    if (failure === 'noneditable') f.button.isContentEditable = false;
    if (failure === 'focus') f.button.getRootNode = () => ({activeElement: null});
    await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: 'type', value: 'Ada', timeout: 1000}}, {}),
      /enabled editable|could not focus/);
    assert.ok(f.inputs.every(input => input[0] !== 'type'));
    assert.ok(f.handles.every(item => item.released));
  }
});

test('createLocatorTool presses trusted keys and releases all modifiers after input or release failures', async () => {
  for (const failure of [null, 'down', 'press', 'up']) {
    const f = fixture();
    const events = [];
    f.page.pptrPage.keyboard = {
      async down(key) { events.push(['down', key]); if (failure === 'down' && key === 'Shift') throw new Error('down failed'); },
      async press(key) { events.push(['press', key]); if (failure === 'press') throw new Error('press failed'); },
      async up(key) { events.push(['up', key]); if (failure === 'up' && key === 'Shift') throw new Error('up failed'); },
    };
    const operation = createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: 'press', key: 'Control+Shift+ArrowLeft', timeout: 1000}},
      {appendResponseLine() {}, attachWaitForResult() {}});
    if (failure) await assert.rejects(operation, /failed/);
    else await operation;
    assert.deepEqual(events, failure === 'down' ? [['down', 'Control'], ['down', 'Shift'], ['up', 'Shift'], ['up', 'Control']] :
      [['down', 'Control'], ['down', 'Shift'], ['press', 'ArrowLeft'], ['up', 'Shift'], ['up', 'Control']]);
    assert.deepEqual(f.inputs, [['focus']]);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('createLocatorTool rejects invalid key combinations before focus or input', async () => {
  for (const key of [undefined, 'InvalidKey', 'Control+Control+A', 'a+b']) {
    const f = fixture();
    await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: 'press', key}}, {}), /requires a key|Invalid key|prefixes/);
    assert.equal(f.handles.length, 0);
    assert.equal(f.inputs.length, 0);
  }
});

test('createLocatorTool checks and unchecks once, skips satisfied states and verifies the result', async () => {
  for (const native of [true, false]) {
    const f = fixture();
    Object.assign(f.button, {tagName: native ? 'INPUT' : 'DIV', type: 'checkbox', checked: false,
      getAttribute: name => name === 'role' ? 'switch' : String(f.button.checked), closest: () => null,
      onClick: () => { f.button.checked = !f.button.checked; }});
    const tool = createLocatorTool({zod, parseKey});
    const dispatch = action => tool.handler({page: f.page,
      params: {query: {css: 'button'}, action, timeout: 1000}}, {appendResponseLine() {}, attachWaitForResult() {}});
    await dispatch('check');
    await dispatch('check');
    assert.equal(f.button.checked, true);
    assert.deepEqual(f.inputs, [['click']]);
    await dispatch('uncheck');
    await dispatch('uncheck');
    assert.equal(f.button.checked, false);
    assert.deepEqual(f.inputs, [['click'], ['click']]);
  }
});

test('createLocatorTool refuses unsupported, disabled and selected-radio transitions without clicking', async () => {
  for (const kind of ['unsupported', 'disabled', 'radio']) {
    const f = fixture();
    Object.assign(f.button, {tagName: 'INPUT', type: kind === 'radio' ? 'radio' : 'checkbox',
      checked: kind === 'radio', indeterminate: kind === 'mixed',
      getAttribute: () => null, closest: () => null, matches: () => kind === 'disabled'});
    if (kind === 'unsupported') f.button.type = 'text';
    await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: kind === 'radio' ? 'uncheck' : 'check', timeout: 1000}}, {}),
      /requires|disabled|Cannot uncheck/);
    assert.deepEqual(f.inputs, []);
  }
});

test('createLocatorTool stops after one click when the checked state does not change', async () => {
  const f = fixture();
  Object.assign(f.button, {tagName: 'INPUT', type: 'checkbox', checked: false,
    getAttribute: () => null, closest: () => null});
  await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page,
    params: {query: {css: 'button'}, action: 'check', timeout: 1000}}, {}), /did not produce/);
  assert.deepEqual(f.inputs, [['click']]);
});

test('createLocatorTool resolves a mixed checkbox with verified intermediate state and at most two clicks', async () => {
  for (const action of ['check', 'uncheck']) {
    const f = fixture();
    Object.assign(f.button, {tagName: 'INPUT', type: 'checkbox', checked: false, indeterminate: true,
      getAttribute: () => null, closest: () => null,
      onClick: () => { f.button.indeterminate = false; f.button.checked = !f.button.checked; }});
    await createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action, timeout: 1000}}, {appendResponseLine() {}, attachWaitForResult() {}});
    assert.equal(f.button.checked, action === 'check');
    assert.equal(f.button.indeterminate, false);
    assert.equal(f.inputs.length, action === 'check' ? 1 : 2);
  }
});

test('withLocator waits only for missing scopes or targets and releases each attempt before retrying', async () => {
  const previousClock = globalThis.performance;
  const previousTimer = globalThis.setTimeout;
  let now = 0;
  globalThis.performance = {now: () => now};
  globalThis.setTimeout = callback => { now += 100; callback(); };
  try {
    const f = fixture();
    let attempts = 0, operations = 0;
    f.document.querySelectorAll = () => {
      attempts++;
      if (attempts > 1) assert.ok(f.handles.slice(0, -1).every(handle => handle.released));
      return attempts < 3 ? [] : [f.button];
    };
    const remaining = await withLocator(f.page, {query: {css: 'button'}, timeout: 500}, (_element, budget) => {
      operations++;
      return budget;
    });
    assert.equal(remaining, 300);
    assert.equal(attempts, 3);
    assert.equal(operations, 1);
    assert.ok(f.handles.every(handle => handle.released));
    f.document.querySelectorAll = () => [];
    await assert.rejects(withLocator(f.page, {query: {css: 'button'}, timeout: 200}, () => {
      throw new Error('must not dispatch');
    }), /presence wait timed out/);
    assert.ok(f.handles.every(handle => handle.released));
  } finally {
    globalThis.performance = previousClock;
    globalThis.setTimeout = previousTimer;
  }
});

test('withLocator never retries an operation even if its error resembles missing resolution', async () => {
  const f = fixture();
  let calls = 0;
  await assert.rejects(withLocator(f.page, {query: {css: 'button'}}, () => {
    calls++;
    throw new Error('Locator requires exactly one match; found 0');
  }), /found 0/);
  assert.equal(calls, 1);
  assert.ok(f.handles.every(handle => handle.released));
});


test('modified click forwards button/count and releases attempted modifiers without replay', async () => {
  for (const failure of [null, 'down', 'click', 'up']) {
    const f = fixture();
    const events = [];
    f.page.pptrPage.keyboard = {
      async down(key) { events.push(['down', key]); if (failure === 'down' && key === 'Shift') throw Error('down failed'); },
      async up(key) { events.push(['up', key]); if (failure === 'up' && key === 'Shift') throw Error('up failed'); },
    };
    f.button.onClick = () => { if (failure === 'click') throw Error('click failed'); };
    const operation = createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
      query: {css: 'button'}, action: 'dblclick', button: 'right', modifiers: ['Alt', 'Shift'], timeout: 1000,
    }}, {appendResponseLine() {}, attachWaitForResult() {}});
    if (failure) await assert.rejects(operation, /failed/); else await operation;
    assert.deepEqual(events, [['down', 'Alt'], ['down', 'Shift'], ['up', 'Shift'], ['up', 'Alt']]);
    assert.deepEqual(f.inputs, failure === 'down' ? [] : [['click', {count: 2, button: 'right'}]]);
    assert.ok(f.handles.every(handle => handle.released));
  }
});

test('click options reject invalid schemas, nonclick use and duplicate platform aliases before input', async () => {
  const tool = createLocatorTool({zod, parseKey});
  const schema = zod.object(tool.schema);
  const base = {query: {css: 'button'}, action: 'click'};
  for (const options of [{button: 'back'}, {modifiers: ['Enter']}, {modifiers: null}, {modifiers: Array(5).fill('Shift')}]) {
    assert.equal(schema.safeParse({...base, ...options}).success, false);
  }
  for (const options of [{action: 'hover', button: 'right'}, {modifiers: ['Shift', 'Shift']},
    {modifiers: ['ControlOrMeta', process.platform === 'darwin' ? 'Meta' : 'Control']}]) {
    const f = fixture();
    await assert.rejects(tool.handler({page: f.page, params: {...base, ...options}}, {}), /Only click|unique/);
    assert.equal(f.handles.length, 0);
    assert.equal(f.inputs.length, 0);
  }
});

function selectFixture() {
  const f = fixture();
  const events = [];
  const options = ['Alpha', 'Beta'].map((label, index) => ({label, value: String(index), index,
    selected: false, matches: () => false}));
  Object.assign(f.button, {tagName: 'SELECT', multiple: true, options, ownerDocument: {defaultView: {Event}},
    dispatchEvent(event) { events.push(event); },
  });
  Object.defineProperty(f.button, 'selectedOptions', {get: () => options.filter(option => option.selected)});
  return {...f, options, events};
}

test('locator select resolves value/label/index descriptors and clear before emitting native selection events', async () => {
  for (const options of ['1', {label: 'Alpha'}, [{index: 0}, {value: '1', label: 'Beta'}], []]) {
    const f = selectFixture();
    await createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: 'select', options, timeout: 1000}},
      {appendResponseLine() {}, attachWaitForResult() {}});
    assert.equal(f.button.selectedOptions.length, Array.isArray(options) ? options.length : 1);
    assert.deepEqual(f.events.map(event => [event.type, event.bubbles, event.isTrusted]),
      [['input', true, false], ['change', true, false]]);
    assert.deepEqual(f.inputs, []);
  }
});

test('locator select rejects unresolved, disabled, duplicate and incompatible selections before mutation', async () => {
  for (const failure of ['missing', 'ambiguous', 'disabled', 'overlap', 'single', 'target']) {
    const f = selectFixture();
    let options = [{index: 0}, {index: 1}];
    if (failure === 'missing') options = [{index: 0}, {value: 'missing'}];
    if (failure === 'ambiguous') { f.options[1].value = '0'; options = ['0']; }
    if (failure === 'disabled') f.options[1].matches = () => true;
    if (failure === 'overlap') options = [{index: 0}, {label: 'Alpha'}];
    if (failure === 'single') f.button.multiple = false;
    if (failure === 'target') f.button.tagName = 'DIV';
    await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page,
      params: {query: {css: 'button'}, action: 'select', options, timeout: 1000}}, {}),
      /exactly one|disabled|overlap|multiple select|native select/);
    assert.equal(f.button.selectedOptions.length, 0);
    assert.deepEqual(f.events, []);
  }
});

test('locator select validates descriptors and stops without replay if a change handler changes selection', async () => {
  const tool = createLocatorTool({zod, parseKey});
  for (const options of [{}, {unknown: 'x'}, {index: -1}, {index: true}, 'x'.repeat(1001), Array(51).fill('x')]) {
    assert.equal(zod.object(tool.schema).safeParse({query: {css: 'select'}, action: 'select', options}).success, false);
  }
  const f = selectFixture();
  f.button.dispatchEvent = event => { f.events.push(event); f.options[0].selected = false; };
  await assert.rejects(tool.handler({page: f.page, params: {
    query: {css: 'button'}, action: 'select', options: {index: 0}, timeout: 1000,
  }}, {}), /changed during event handling/);
  assert.equal(f.events.length, 2);
});


test('wrapped control contents do not become part of its own label', async () => {
  const f = selectFixture();
  const label = {childNodes: [{nodeType: 3, textContent: 'Language'}, f.button]};
  Object.assign(f.button, {labels: [label], getAttribute: () => null,
    childNodes: [{nodeType: 3, textContent: 'English French'}]});
  f.document.querySelectorAll = () => [f.button];
  await createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
    query: {label: 'Language'}, action: 'select', options: {index: 1}, timeout: 1000,
  }}, {appendResponseLine() {}, attachWaitForResult() {}});
  assert.deepEqual(f.button.selectedOptions.map(option => option.label), ['Beta']);
});


test('role locators own AX handles and reject ambiguity before input', async () => {
  for (const ambiguous of [false, true]) {
    const f = fixture();
    f.document.axMatches = [f.document, f.button, ...(ambiguous ? [f.button] : [])];
    let dispatched = 0;
    const result = withLocator(f.page, {query: {role: 'button', name: 'Save'}}, () => ++dispatched);
    if (ambiguous) await assert.rejects(result, /exactly one match; found 2/);
    else assert.equal(await result, 1);
    assert.equal(dispatched, ambiguous ? 0 : 1);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('text refinements run before explicit occurrence selection for DOM and AX queries', async () => {
  for (const base of [{css: 'button'}, {role: 'button', name: 'Save'}]) {
    const f = fixture();
    const nodes = ['Ada inactive', 'ADA  active', 'Grace active'].map(textContent => ({...f.button, textContent}));
    f.document.querySelectorAll = () => nodes;
    f.document.axMatches = [f.document, ...nodes];
    const query = {...base, hasText: 'ACTIVE', hasNotText: 'inactive', nth: -1};
    const picked = await withLocator(f.page, {query}, element => element.node.textContent);
    assert.equal(picked, 'Grace active');
    assert.ok(f.handles.every(item => item.released));
  }
});

test('missing occurrence waits without dispatch and malformed refinements fail schema validation', async () => {
  const f = fixture();
  let dispatches = 0;
  await assert.rejects(withLocator(f.page, {query: {css: 'button', nth: 1}, timeout: 10}, () => ++dispatches), /timed out/);
  assert.equal(dispatches, 0);
  assert.ok(f.handles.every(item => item.released));
  const schema = createLocatorTool({zod, parseKey}).schema.query;
  for (const extra of [{nth: -2}, {nth: 0.5}, {nth: true}, {hasText: null}, {hasNotText: 'x'.repeat(1001)}]) {
    assert.equal(schema.safeParse({css: 'button', ...extra}).success, false);
  }
  assert.equal(schema.safeParse({role: 'button', hasText: '', nth: 0}).success, true);
});

test('text locators select the smallest normalized match and preserve exact-case matching', async () => {
  for (const exact of [false, true]) {
    const f = fixture();
    const child = {...f.button, textContent: 'Save\n changes', childNodes: [{nodeType: 3, textContent: 'Save\n changes'}], children: []};
    const parent = {...f.button, childNodes: [child], children: [child]};
    const script = {...f.button, tagName: 'SCRIPT', textContent: 'Save changes'};
    const headChild = {...child, closest: () => ({tagName: 'HEAD'})};
    f.document.querySelectorAll = () => [parent, child, script, headChild];
    const query = {text: exact ? 'Save changes' : 'SAVE', exact};
    const result = await withLocator(f.page, {query}, handle => handle.node);
    assert.equal(result, child);
    assert.ok(f.handles.every(handle => handle.released));
  }
});

test('text locators include input button values and refuse ambiguous matches', async () => {
  const f = fixture();
  const input = {...f.button, tagName: 'INPUT', type: 'submit', value: 'Send', children: []};
  f.document.querySelectorAll = () => [input];
  assert.equal(await withLocator(f.page, {query: {text: 'Send', exact: true}}, h => h.node), input);
  f.document.querySelectorAll = () => [input, {...input}];
  await assert.rejects(withLocator(f.page, {query: {text: 'Send'}}, () => assert.fail('ambiguous input')), /found 2/);
});

test('text locator schema limits exact to boolean text selectors', () => {
  const schema = zod.object(createLocatorTool({zod, parseKey}).schema);
  for (const query of [{text: 'Save'}, {text: 'Save', exact: true, nth: -1}]) {
    assert.equal(schema.safeParse({query, action: 'click'}).success, true);
  }
  for (const query of [{text: ''}, {text: 'Save', exact: 1}, {css: 'button', exact: true}]) {
    assert.equal(schema.safeParse({query, action: 'click'}).success, false);
  }
});

test('visibility filtering precedes occurrence selection and does not silently pick among visible duplicates', async () => {
  const f = fixture();
  const hidden = {...f.button, checkVisibility: () => false, getBoundingClientRect: () => ({width: 10, height: 10})};
  const visible = {...hidden, checkVisibility: () => true};
  f.document.querySelectorAll = () => [hidden, visible];
  assert.equal(await withLocator(f.page, {query: {css: 'button', visible: true, nth: 0}}, h => h.node), visible);
  assert.equal(await withLocator(f.page, {query: {css: 'button', visible: false}}, h => h.node), hidden);
  f.document.querySelectorAll = () => [visible, {...visible}];
  await assert.rejects(withLocator(f.page, {query: {css: 'button', visible: true}}, () => assert.fail('ambiguous')), /found 2/);
});

test('visibility filtering includes the embedding iframe before any input', async () => {
  const f = fixture();
  Object.assign(f.frameElement, {checkVisibility: () => false, getBoundingClientRect: () => ({width: 100, height: 100})});
  Object.assign(f.button, {checkVisibility: () => true, getBoundingClientRect: () => ({width: 10, height: 10})});
  const within = [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}];
  assert.equal(await withLocator(f.page, {within, query: {css: 'button', visible: false}}, h => h.node), f.button);
  await assert.rejects(withLocator(f.page, {within, query: {css: 'button', visible: true}, timeout: 20},
    () => assert.fail('hidden iframe input')), /timed out before input/);
  assert.ok(f.handles.every(handle => handle.released));
});

test('visibility query schema accepts booleans only', () => {
  const schema = zod.object(createLocatorTool({zod, parseKey}).schema);
  for (const visible of [true, false]) assert.equal(schema.safeParse({query: {css: 'button', visible}, action: 'click'}).success, true);
  for (const visible of [0, 1, 'true', null]) assert.equal(schema.safeParse({query: {css: 'button', visible}, action: 'click'}).success, false);
});

test('withLocator filters role targets by relative nested descendants before occurrence selection', async () => {
  const f = fixture();
  const marker = {getAttribute: key => key === 'data-testid' ? 'ready' : null};
  const nested = {querySelectorAll: selector => selector === '[data-testid]' ? [marker, marker] : []};
  f.button.querySelectorAll = selector => selector === '.nested' ? [nested] : [];
  const cancelled = {...f.button, querySelectorAll: selector => selector === '.cancelled' ? [marker] : f.button.querySelectorAll(selector)};
  const empty = {...f.button, querySelectorAll: () => []};
  f.document.axMatches = [empty, f.button, cancelled];
  const query = {role: 'button', name: 'Save', has: {css: '.nested', has: {testId: 'ready'}}, hasNot: {css: '.cancelled'}, nth: -1};
  await withLocator(f.page, {query}, handle => assert.equal(handle.node, f.button));
  assert.ok(f.handles.every(handle => handle.released));
});

test('withLocator propagates embedding frame visibility into nested descendant filters', async () => {
  const f = fixture();
  f.frameElement.checkVisibility = () => false;
  f.frameElement.getBoundingClientRect = () => ({width: 50, height: 50});
  const marker = {checkVisibility: () => true, getBoundingClientRect: () => ({width: 10, height: 10})};
  f.button.querySelectorAll = selector => selector === '.marker' ? [marker] : [];
  await withLocator(f.page, {within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}],
    query: {css: 'button', has: {css: '.marker', visible: false}}}, handle => assert.equal(handle.node, f.button));
  assert.ok(f.handles.every(handle => handle.released));
});

test('withLocator descendant work exhaustion fails before input without presence retries and releases handles', async () => {
  const f = fixture();
  f.button.querySelectorAll = () => [];
  let resolutions = 0;
  f.document.querySelectorAll = () => { resolutions++; return Array(10001).fill(f.button); };
  let dispatched = false;
  await assert.rejects(withLocator(f.page, {query: {css: 'button', has: {css: '.missing'}}}, () => { dispatched = true; }), /10000 checks/);
  assert.equal(dispatched, false); assert.equal(resolutions, 1);
  assert.ok(f.handles.every(handle => handle.released));
});

test('createLocatorTool bounds descendant schema depth and rejects frame children', () => {
  const schema = createLocatorTool({zod, parseKey}).schema.query;
  let query = {testId: 'ready'};
  for (let i = 0; i < 3; i++) query = {css: '.row', has: query};
  assert.ok(schema.safeParse(query).success);
  for (const invalid of [{css: '.row', has: query}, {css: '.row', hasNot: null},
    {css: '.row', has: {frame: {css: 'iframe'}}}]) {
    assert.equal(schema.safeParse(invalid).success, false);
  }
});

test('composed input selectors intersect and deduplicate in document order before nth', async () => {
  for (const [query, expected] of [
    [{css: '.left', and: {testId: 'chosen'}}, 'B'],
    [{css: '.right', or: {css: '.left'}, nth: 0}, 'A'],
    [{css: '.right', or: {css: '.left'}, nth: -1}, 'C'],
  ]) {
    const f = fixture();
    const nodes = ['A', 'B', 'C'].map((textContent, index) => ({isConnected: true, textContent,
      getAttribute: name => name === 'data-testid' && index === 1 ? 'chosen' : null,
      compareDocumentPosition: other => index < nodes.indexOf(other) ? 4 : 2}));
    f.document.querySelectorAll = selector => ({'.left': nodes.slice(0, 2), '.right': nodes.slice(1),
      '[data-testid]': nodes})[selector] ?? [];
    let actions = 0;
    await withLocator(f.page, {query}, element => {
      actions++;
      assert.equal(element.node.textContent, expected);
    });
    assert.equal(actions, 1);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('composition cannot dispatch ambiguous input or replay a failed action', async () => {
  const f = fixture();
  const other = {...f.button, compareDocumentPosition: () => 2};
  f.button.compareDocumentPosition = () => 4;
  f.document.querySelectorAll = selector => selector === '.first' ? [f.button] : [other];
  let calls = 0;
  await assert.rejects(withLocator(f.page, {query: {css: '.first', or: {css: '.second'}}}, () => calls++),
    /exactly one match; found 2/);
  assert.equal(calls, 0);
  await assert.rejects(withLocator(f.page, {query: {css: '.first', or: {css: '.second'}, nth: 0}}, () => {
    calls++;
    throw Error('Input failed');
  }), /Input failed/);
  assert.equal(calls, 1);
  assert.ok(f.handles.every(item => item.released));
});

test('composition schema supports bounded DOM branches and refuses ambiguous precedence', () => {
  const schema = zod.object(createLocatorTool({zod, parseKey}).schema);
  assert.equal(schema.safeParse({action: 'click', query: {role: 'button', name: 'Save',
    and: {role: 'button', name: 'Save'}}}).success, true);
  for (const query of [
    {css: 'button', and: {css: '.a'}, or: {css: '.b'}},
    {css: 'button', or: null},
    {css: 'button', or: {css: 'x', or: {css: 'x', or: {css: 'x', or: {css: 'x'}}}}},
  ]) assert.equal(schema.safeParse({action: 'click', query}).success, false);
});

test('nested role descendants stay in their candidate and identical AX queries are reused', async () => {
  const f = fixture();
  const target = {isConnected: true}, outside = {isConnected: true};
  const a = {isConnected: true, contains: node => node === outside};
  const b = {isConnected: true, contains: node => node === target};
  f.document.querySelectorAll = () => [a, b];
  let axCalls = 0;
  f.document.axQuery = (name, role) => {
    assert.equal(name, 'Delete'); assert.equal(role, 'button'); axCalls++;
    return [target, b]; // Candidate itself must not satisfy its own descendant test.
  };
  await withLocator(f.page, {query: {css: '.row', has: {role: 'button', name: 'Delete'},
    hasNot: {role: 'button', name: 'Delete', hasText: 'cancelled'}}}, element => {
    assert.equal(element.node, b);
  });
  assert.equal(axCalls, 1);
  assert.ok(f.handles.every(item => item.released));
});

test('role composition keeps separate candidate sets for different accessible names', async () => {
  const f = fixture();
  const other = {isConnected: true, compareDocumentPosition: () => 2};
  f.button.compareDocumentPosition = () => 4;
  f.document.axQuery = (name, role) => {
    assert.equal(role, 'button');
    return name === 'Save' ? [f.button] : [other];
  };
  await withLocator(f.page, {query: {role: 'button', name: 'Save',
    or: {role: 'button', name: 'Cancel'}, nth: -1}}, element => assert.equal(element.node, other));
  assert.ok(f.handles.every(item => item.released));
});

test('excess AX candidates fail before dispatch and release all acquired handles', async () => {
  const f = fixture();
  f.document.axQuery = () => Array(10001).fill(f.button);
  let dispatched = false;
  await assert.rejects(withLocator(f.page, {query: {css: '.row', has: {role: 'button'}}}, () => {
    dispatched = true;
  }), /exceeds 10000 candidates/);
  assert.equal(dispatched, false);
  assert.ok(f.handles.every(item => item.released));
});

test('locator role reads return selected fields without input or duplicate snapshots', async () => {
  const f = fixture();
  f.document.axMatches = [f.button];
  Object.assign(f.button, {innerText: 'Save', textContent: 'Save', disabled: true});
  f.button.getAttribute = name => name === 'data-key' ? 'primary' : null;
  const lines = [];
  await createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
    query: {role: 'button', name: 'Save'}, action: 'read', fields: ['text', 'disabled', 'attr:data-key'],
  }}, {appendResponseLine: line => lines.push(line)});
  const result = JSON.parse(lines[0]);
  assert.equal(result.count, 1);
  assert.deepEqual(result.records, [{truncated: false, text: 'Save', disabled: true, 'attr:data-key': 'primary'}]);
  assert.deepEqual(f.inputs, []);
  assert.ok(f.handles.every(item => item.released));
});

test('locator collections preserve total count and page all role matches', async () => {
  const f = fixture();
  f.document.axMatches = ['Alpha', 'Beta', 'Gamma'].map(text => ({...f.button, textContent: text}));
  const tool = createLocatorTool({zod, parseKey});
  const read = async params => {
    let result;
    await tool.handler({page: f.page, params: {query: {role: 'button'}, ...params}},
      {appendResponseLine: line => { result = JSON.parse(line); }});
    return result;
  };
  const first = await read({action: 'read-all', fields: ['textContent'], limit: 2});
  assert.equal(first.count, 3);
  assert.equal(first.nextOffset, 2);
  assert.equal(first.omitted, 1);
  assert.deepEqual(first.records.map(row => row.textContent), ['Alpha', 'Beta']);
  const last = await read({action: 'read-all', fields: ['textContent'], offset: 2, limit: 2});
  assert.equal(last.nextOffset, null);
  assert.deepEqual(last.records.map(row => row.textContent), ['Gamma']);
  const count = await read({action: 'count'});
  assert.equal(count.count, 3);
  assert.deepEqual(count.records, []);
  f.document.axMatches = [];
  assert.equal((await read({action: 'count'})).count, 0);
  assert.equal((await read({action: 'read-all'})).nextOffset, null);
  assert.ok(f.handles.every(item => item.released));
  assert.deepEqual(f.inputs, []);
});

test('locator read bounds UTF16 and escaped JSON while masking password attributes', async () => {
  const f = fixture();
  f.button.type = 'password';
  f.button.value = 'secret';
  f.button.textContent = '\u0000😀'.repeat(2000);
  f.button.getAttribute = name => name.toLowerCase() === 'value' ? 'secret' : f.button.textContent;
  let result;
  await createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
    query: {css: 'button'}, action: 'read',
    fields: ['textContent', 'value', 'attr:VALUE', ...Array.from({length: 9}, (_, i) => 'attr:data-' + i)],
  }}, {appendResponseLine: line => { result = JSON.parse(line); }});
  assert.equal(result.records[0].value, '[password value omitted]');
  assert.equal(result.records[0]['attr:VALUE'], '[password value omitted]');
  assert.equal(result.records[0].truncated, true);
  assert.ok(JSON.stringify(result.records[0]).length <= 6000);
  for (const value of Object.values(result.records[0]).filter(value => typeof value === 'string')) {
    assert.ok(value.length <= 1000);
    assert.ok(!/[\uD800-\uDBFF]$/.test(value));
  }
});

test('locator collection reads retain unique frame and shadow scope checks', async () => {
  const f = fixture();
  f.button.textContent = 'Inside frame';
  let result;
  await createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
    within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}], query: {css: 'button'},
    action: 'read-all', fields: ['textContent'],
  }}, {appendResponseLine: line => { result = JSON.parse(line); }});
  assert.equal(result.records[0].textContent, 'Inside frame');
  assert.ok(f.handles.every(item => item.released));
  f.document.querySelectorAll = () => [f.host, f.host];
  await assert.rejects(createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
    within: [{shadow: {css: '#host'}}], query: {css: 'button'}, action: 'count',
  }}, {}), /exactly one/);
});

test('locator read rejects ambiguous targets and invalid operation-specific options before input', async () => {
  const f = fixture();
  f.document.axMatches = [f.button, f.button];
  const tool = createLocatorTool({zod, parseKey});
  await assert.rejects(tool.handler({page: f.page, params: {action: 'read', query: {role: 'button'}}}, {}), /exactly one/);
  for (const params of [
    {action: 'count', fields: ['text']}, {action: 'read', offset: 1},
    {action: 'click', fields: ['text']}, {action: 'read-all', includeSnapshot: true},
    {action: 'read', value: 'no'}, {action: 'read-all', button: 'left'},
  ]) await assert.rejects(tool.handler({page: f.page, params: {query: {css: 'button'}, ...params}}, {}));
  assert.deepEqual(f.inputs, []);
  assert.ok(f.handles.every(item => item.released));
  const schema = zod.object(tool.schema);
  for (const params of [
    {fields: ['unknown']}, {fields: ['text', 'text']}, {limit: 51}, {offset: -1},
  ]) assert.equal(schema.safeParse({action: 'read-all', query: {role: 'button'}, ...params}).success, false);
});

test('role state waits poll fresh matches and release every handle without input', async () => {
  for (const state of ['attached', 'detached', 'visible', 'hidden']) {
    const f = fixture();
    let attempts = 0;
    f.button.getBoundingClientRect = () => ({width: 10, height: 10});
    f.button.checkVisibility = () => true;
    f.document.axQuery = () => {
      const ready = ++attempts >= 2;
      return (['attached', 'visible'].includes(state) ? ready : !ready) ? [f.button] : [];
    };
    let result;
    await createLocatorTool({zod, parseKey}).handler({page: f.page, params: {
      action: 'wait', query: {role: 'button'}, waitState: state, timeout: 1000,
    }}, {appendResponseLine: line => { result = JSON.parse(line); }});
    assert.equal(result.state, state);
    assert.equal(result.count, ['attached', 'visible'].includes(state) ? 1 : 0);
    assert.deepEqual(result.records, []);
    assert.equal(attempts, 2);
    assert.deepEqual(f.inputs, []);
    assert.ok(f.handles.every(item => item.released));
  }
});

test('state waits account for embedding frame visibility and do not treat missing scopes as hidden', async () => {
  const f = fixture();
  f.frameElement.getBoundingClientRect = f.button.getBoundingClientRect = () => ({width: 10, height: 10});
  f.frameElement.checkVisibility = () => false;
  f.button.checkVisibility = () => true;
  f.frameElement.frameDocument.axMatches = [f.button];
  const params = {action: 'wait', query: {role: 'button'}, waitState: 'hidden', timeout: 1000,
    within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}]};
  let result;
  const tool = createLocatorTool({zod, parseKey});
  await tool.handler({page: f.page, params}, {appendResponseLine: line => {result = JSON.parse(line);}});
  assert.equal(result.count, 1);
  assert.equal(result.state, 'hidden');
  f.document.querySelectorAll = () => [];
  await assert.rejects(tool.handler({page: f.page, params}, {}), /exactly one/);
  assert.ok(f.handles.every(item => item.released));
});

test('state waits fail closed for ambiguity, deadline and invalid option combinations', async () => {
  const f = fixture(), tool = createLocatorTool({zod, parseKey});
  const params = {action: 'wait', query: {role: 'button'}, waitState: 'attached', timeout: 20};
  f.document.axMatches = [f.button, f.button];
  await assert.rejects(tool.handler({page: f.page, params}, {}), /at most one/);
  f.document.axMatches = [];
  await assert.rejects(tool.handler({page: f.page, params}, {}), /timed out/);
  for (const invalid of [
    {...params, fields: ['text']}, {...params, action: 'count'}, {...params, waitState: undefined},
    {...params, includeSnapshot: true}, {...params, offset: 0},
  ]) await assert.rejects(tool.handler({page: f.page, params: invalid}, {}));
  assert.deepEqual(f.inputs, []);
  assert.ok(f.handles.every(item => item.released));
});

test('visible field returns booleans for single and collection reads including hidden embedding frames', async () => {
  const f = fixture(), tool = createLocatorTool({zod, parseKey});
  let frameVisible = true, nodeVisible = true, width = 10;
  f.button.checkVisibility = () => nodeVisible;
  f.button.getBoundingClientRect = () => ({width, height: 10});
  f.frameElement.checkVisibility = () => frameVisible;
  f.frameElement.getBoundingClientRect = () => ({width: 10, height: 10});
  f.frameElement.frameDocument.axMatches = [f.button];
  const params = {query: {role: 'button'}, fields: ['visible'],
    within: [{shadow: {css: '#host'}}, {frame: {css: 'iframe'}}]};
  for (const action of ['read', 'read-all']) {
    for (const settings of [[true, true, 10, true], [false, true, 10, false],
      [true, false, 10, false], [true, true, 0, false]]) {
      [frameVisible, nodeVisible, width] = settings;
      let result;
      await tool.handler({page: f.page, params: {...params, action}},
        {appendResponseLine: line => {result = JSON.parse(line);}});
      assert.deepEqual(result.records, [{truncated: false, visible: settings[3]}]);
    }
  }
  assert.ok(f.handles.every(handle => handle.released));
  assert.deepEqual(f.inputs, []);
  assert.equal(zod.object(tool.schema).safeParse({...params, action: 'read'}).success, true);
});

test('enabled field respects native disabling, ARIA role applicability and inherited overrides', async () => {
  const f = fixture();
  const node = (tagName, attrs = {}, parentElement = null) => ({tagName, parentElement, isConnected: true,
    type: 'text', hidden: false, getRootNode: () => ({}),
    getAttribute: name => attrs[name] ?? null, hasAttribute: name => name in attrs,
    matches: selector => selector === ':disabled' && !!attrs.disabled});
  const ancestor = node('DIV', {'aria-disabled': 'true'});
  const values = [node('BUTTON'), node('BUTTON', {disabled: true}), node('BUTTON', {}, ancestor),
    node('BUTTON', {'aria-disabled': 'false'}, ancestor), node('DIV', {'aria-disabled': 'true'}),
    node('DIV', {role: 'invalid button', 'aria-disabled': 'true'}),
    node('BUTTON', {role: 'presentation', 'aria-disabled': 'true'}),
    node('DIV', {role: 'checkbox', 'aria-disabled': 'TRUE'})];
  const expected = [true, false, false, true, true, false, false, false];
  const shadowButton = node('BUTTON');shadowButton.getRootNode = () => ({host: ancestor});
  values.push(shadowButton);expected.push(false);
  f.document.querySelectorAll = () => values;
  let result;
  const tool = createLocatorTool({zod, parseKey});
  await tool.handler({page:f.page,params:{query:{css:'*'},action:'read-all',fields:['enabled']}},
    {appendResponseLine:line=>{result=JSON.parse(line)}});
  assert.deepEqual(result.records.map(record=>record.enabled),expected);
  assert.ok(f.handles.every(handle=>handle.released));
  assert.deepEqual(f.inputs,[]);
  assert.equal(zod.object(tool.schema).safeParse({query:{css:'button'},action:'read',fields:['enabled']}).success,true);
});


test('text refinements ignore script/style/comment contents and include submit values for DOM and AX targets', async () => {
  for (const base of [{css: '*'}, {role: 'button'}]) {
    const f = fixture();
    const container = {...f.button, textContent: 'Readypoison', childNodes: [
      {nodeType: 3, textContent: 'Ready'},
      {tagName: 'SCRIPT', textContent: 'poison'},
      {tagName: 'STYLE', textContent: 'poison'},
      {nodeType: 8, textContent: 'poison'},
    ]};
    const submit = {...f.button, tagName: 'INPUT', type: 'submit', value: 'Send order',
      textContent: '', childNodes: []};
    f.document.querySelectorAll = () => [container, submit];
    f.document.axMatches = [container, submit];
    for (const [refinements, expected] of [
      [{hasText: 'READY', hasNotText: 'poison'}, container],
      [{hasText: 'send order'}, submit],
      [{hasNotText: 'send order'}, container],
    ]) {
      assert.equal(await withLocator(f.page, {query: {...base, ...refinements}}, handle => handle.node), expected);
    }
    let dispatched = false;
    await assert.rejects(withLocator(f.page, {query: {...base, hasText: 'poison'}, timeout: 10}, () => {
      dispatched = true;
    }), /timed out/);
    assert.equal(dispatched, false);
    assert.ok(f.handles.every(handle => handle.released));
  }
});


test('regex text, label, placeholder and filters preserve raw text and reset state', async () => {
  for (const key of ['text', 'label', 'placeholder', 'hasText', 'hasNotText']) {
    const f = fixture();
    const nodes = [0, 1].map(() => ({...f.button, textContent: 'Save\n order', children: [],
      childNodes: [{nodeType: 3, textContent: 'Save\n order'}], labels: [],
      getAttribute: name => ['aria-label', 'placeholder'].includes(name) ? 'Save\n order' : null}));
    f.document.querySelectorAll = () => nodes;
    for (const flags of ['g', 'y', 'i']) {
      const matcher = {regex: '^Save\\n order$', flags};
      const query = {...(['hasText', 'hasNotText'].includes(key) ? {css: '*'} : {}), [key]: matcher};
      if (key === 'hasNotText') {
        await assert.rejects(withLocator(f.page, {query, timeout: 1}, () => assert.fail('unexpected input')), /timed out/);
      } else {
        await assert.rejects(withLocator(f.page, {query}, () => assert.fail('ambiguous input')), /found 2/);
        assert.equal(await withLocator(f.page, {query: {...query, nth: 1}}, h => h.node), nodes[1]);
      }
    }
    assert.ok(f.handles.every(h => h.released));
  }
});

test('regex schema rejects invalid patterns and flags before resolving a page', () => {
  const schema = createLocatorTool({zod, parseKey}).schema.query;
  for (const matcher of [{regex: '['}, {regex: 'x', flags: 'ii'}, {regex: 'x', flags: 'uv'},
    {regex: 'x', flags: 'z'}, {regex: 2}, {regex: 'x', extra: true}]) {
    for (const query of [{text: matcher}, {label: matcher}, {placeholder: matcher},
      {role: 'button', name: matcher}, {css: '*', hasText: matcher}]) {
      assert.equal(schema.safeParse(query).success, false);
    }
  }
  assert.equal(schema.safeParse({text: {regex: '', flags: 'g'}}).success, true);
});


test('role regex filters computed AX names and owns adopted handles', async () => {
  const f = fixture();
  const selected = {...f.button, textContent: 'DOM text differs'};
  f.document.backendNodes = {1: selected};
  f.document.axNodes = [
    {ignored: true, role: {value: 'button'}, name: {value: 'Save order'}, backendDOMNodeId: 9},
    {role: {value: 'StaticText'}, name: {value: 'Save order'}, backendDOMNodeId: 8},
    {role: {value: 'button'}, name: {value: 'Cancel'}, backendDOMNodeId: 7},
    {role: {value: 'button'}, name: {value: 'Save order'}, backendDOMNodeId: 1},
  ];
  const result = await withLocator(f.page, {query: {role: 'button', name: {regex: '^save', flags: 'ig'}}}, h => h.node);
  assert.equal(result, selected);
  assert.ok(f.handles.every(h => h.released));
});


test('expected navigation arms before a fast action and preserves its result', async () => {
  const order=[];let complete;let signal;
  const page={url:()=> 'https://example.com/done',waitForNavigation:options=>{
    order.push('armed');signal=options.signal;assert.equal(options.waitUntil,'networkidle0');
    return new Promise(resolve=>{complete=resolve;});
  }};
  const result=await withExpectedNavigation(page,{url:{regex:'/done$',flags:'g'},loadState:'networkidle'},async()=>{
    order.push('action');complete();return {completed:true};
  });
  assert.deepEqual(order,['armed','action']);assert.deepEqual(result,{completed:true});assert.equal(signal.aborted,true);
});

test('expected navigation cancels its listener on action failure without replay', async () => {
  let calls=0,cancelled=false;
  const page={waitForNavigation:({signal})=>new Promise((resolve,reject)=>{
    signal.addEventListener('abort',()=>{cancelled=true;reject(new Error('cancelled'));},{once:true});
  })};
  await assert.rejects(withExpectedNavigation(page,{},async()=>{calls++;throw new Error('input failed');}),/input failed/);
  assert.equal(calls,1);assert.equal(cancelled,true);
});

test('expected navigation rejects timeout and wrong URL after only one action', async () => {
  for(const timeout of [true,false]){
    let calls=0;
    const page={url:()=> 'https://example.com/wrong',waitForNavigation:()=>timeout?
      Promise.reject(new Error('navigation timed out')):Promise.resolve(null)};
    await assert.rejects(withExpectedNavigation(page,{url:'https://example.com/done'},async()=>++calls),
      timeout?/navigation timed out/:/unexpected URL/);
    assert.equal(calls,1);
  }
});

test('explicit navigation states bypass the generic full-load action wait', async () => {
  for (const state of ['commit','domcontentloaded','load','networkidle']) {
    const f=fixture();let armed=false,onCommit;
    const frame=f.page.pptrPage.mainFrame();f.page.pptrPage.mainFrame=()=>frame;
    f.page.pptrPage.on=(event,fn)=>{assert.equal(event,'framenavigated');onCommit=fn;};
    f.page.pptrPage.off=(event,fn)=>assert.equal(fn,onCommit);
    f.page.waitForEventsAfterAction=()=>assert.fail('Explicit wait must own navigation timing');
    f.page.pptrPage.url=()=> 'https://example.com/done';
    f.page.pptrPage.waitForNavigation=async options=>{
      armed=true;assert.deepEqual(options.waitUntil,state==='commit'?[]:state==='networkidle'?'networkidle0':state);
    };
    f.button.onClick=()=>{assert.equal(armed,true);onCommit?.(frame);};
    await createLocatorTool({zod,parseKey}).handler({page:f.page,params:{query:{css:'button'},action:'click',timeout:1000,navigation:{loadState:state}}},{
      appendResponseLine(){},attachWaitForResult(result){assert.deepEqual(result,{navigatedToUrl:'https://example.com/done',dialogHandled:false});}
    });
    assert.deepEqual(f.inputs,[['click']]);assert.ok(f.handles.every(h=>h.released));
  }
});


test('commit wait ignores child frames and removes listeners on action failure', async () => {
  const main={};let listener,removed=false;
  const page={mainFrame:()=>main,on:(_event,fn)=>{listener=fn;},off:(_event,fn)=>{assert.equal(fn,listener);removed=true;},
    waitForNavigation:({signal})=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new Error('aborted')),{once:true}))};
  await assert.rejects(withExpectedNavigation(page,{loadState:'commit'},async()=>{
    listener({});throw new Error('input failed');
  }),/input failed/);
  assert.equal(removed,true);
});


test('loading role reads use computed AX names and exclude ignored and out-of-scope nodes', async () => {
  for (const readyState of ['loading', 'interactive']) for (const name of ['Save order', {regex: '^save', flags: 'ig'}, undefined]) {
    const f = fixture();
    f.document.readyState = readyState;
    f.document.axQuery = () => { throw new Error('must not wait for queryAXTree'); };
    const shadowRoot = {host: f.host, getRootNode() { return this; }};
    f.host.parentNode = f.document;
    const selected = {...f.button, parentNode: shadowRoot, textContent: 'Different DOM text'};
    const outside = {...f.button, getRootNode: () => ({})};
    f.document.backendNodes = {1: selected, 2: outside};
    f.document.axNodes = [
      {ignored: true, role: {value: 'button'}, name: {value: 'Save order'}, backendDOMNodeId: 9},
      {role: {value: 'heading'}, name: {value: 'Save order'}, backendDOMNodeId: 8},
      {role: {value: 'button'}, name: {value: 'Save order'}, backendDOMNodeId: 2},
      {role: {value: 'button'}, name: {value: 'Save order'}, backendDOMNodeId: 1},
    ];
    const result = await withLocator(f.page, {query: {role: 'button', ...(name === undefined ? {} : {name})}}, h => h.node);
    assert.equal(result, selected);
    assert.ok(f.handles.every(h => h.released));
  }
});


function downloadFixture() {
  const session = new EventEmitter();
  const commands = [];
  let detached = false;
  session.send = async command => commands.push(command);
  session.detach = async () => { detached = true; };
  const page = {createCDPSession: async () => session, frames: () => [{_id: 'owned'}]};
  const begin = (frameId = 'owned') => session.emit('Page.downloadWillBegin', {
    frameId, guid: 'fixture-guid', url: 'https://example.test/file', suggestedFilename: 'fixture.txt',
  });
  const progress = (state, guid = 'fixture-guid') => session.emit('Page.downloadProgress', {
    guid, state, receivedBytes: 12,
  });
  const verify = () => {
    assert.equal(detached, true);
    assert.equal(session.listenerCount('Page.downloadWillBegin'), 0);
    assert.equal(session.listenerCount('Page.downloadProgress'), 0);
    assert.deepEqual(commands, ['Page.enable']);
  };
  return {page, begin, progress, verify};
}

test('download wait arms before input and returns a compact completion receipt', async () => {
  const f = downloadFixture();let inputs = 0;
  const result = await withExpectedDownload(f.page, {}, async () => {
    inputs++;f.begin('unrelated');f.progress('completed');
    f.begin();f.progress('completed', 'unrelated');f.progress('completed');
  });
  assert.deepEqual(result, {state: 'completed', guid: 'fixture-guid', url: 'https://example.test/file',
    suggestedFilename: 'fixture.txt', receivedBytes: 12});
  assert.equal(inputs, 1);f.verify();
});

test('download wait distinguishes start, cancellation and timeout without replay', async () => {
  for (const outcome of ['started', 'canceled', 'timeout', 'input-error']) {
    const f = downloadFixture();let inputs = 0;
    const operation = withExpectedDownload(f.page, {state: outcome === 'started' ? 'started' : 'completed', timeout: 10}, async () => {
      inputs++;
      if (outcome === 'input-error') throw new Error('input failed');
      f.begin();if (outcome === 'canceled') f.progress('canceled');
    });
    if (outcome === 'started') assert.equal((await operation).state, 'started');
    else await assert.rejects(operation, outcome === 'input-error' ? /input failed/ : outcome === 'canceled' ? /canceled/ : /timed out/);
    assert.equal(inputs, 1);f.verify();
  }
});

test('locator input integrates a prearmed download and returns its receipt without navigation waits', async () => {
  const f = fixture(), d = downloadFixture(), lines = [];
  Object.assign(f.page.pptrPage, d.page);
  f.page.waitForEventsAfterAction = () => { throw new Error('Unexpected navigation wait'); };
  f.button.onClick = () => {d.begin();d.progress('completed');};
  await createLocatorTool({zod,parseKey}).handler({page:f.page,params:{
    query:{css:'button'},action:'click',timeout:1000,download:{state:'completed',timeout:100},
  }},{appendResponseLine:line=>lines.push(line),attachWaitForResult:()=>{}});
  assert.equal(f.inputs.length,1);
  assert.equal(JSON.parse(lines[1]).download.state,'completed');
  d.verify();
  for (const params of [{action:'read',download:{}},{action:'click',download:{},navigation:{}}]) {
    await assert.rejects(createLocatorTool({zod,parseKey}).handler({page:f.page,params:{query:{css:'button'},...params}},{}),/requires input|mutually exclusive/);
  }
});


test('browser clipboard preserves ordered MIME payloads and stays isolated by context and store', () => {
  const store = createBrowserClipboardStore(), first = {}, second = {};
  const items = [
    {presentationStyle:'inline',entries:[{mimeType:'text/plain',text:'A😀'},{mimeType:'text/html',text:'<b>A😀</b>'}]},
    {presentationStyle:'attachment',entries:[{mimeType:'image/png',base64:Buffer.from([0,1,2,255]).toString('base64')}]},
  ];
  assert.deepEqual(store.read(first), []);
  const written = store.write(first, items);
  assert.equal(written.itemCount,2);assert.equal(written.entryCount,3);
  assert.equal(written.bytes,Buffer.byteLength('A😀<b>A😀</b>')+4);
  assert.deepEqual(store.read(first),items);assert.equal(store.readText(first),'A😀');
  assert.deepEqual(store.read(second),[]);
  assert.deepEqual(createBrowserClipboardStore().read(first),[]);
  items[0].entries[0].text='caller changed';
  const read=store.read(first);read[0].entries[0].text='reader changed';
  assert.equal(store.readText(first),'A😀');
  assert.deepEqual(store.write(first,[]),{itemCount:0,entryCount:0,bytes:0});
  assert.deepEqual(store.read(first),[]);assert.equal(store.readText(first),'');
});

test('browser clipboard rejects malformed and oversized writes atomically', () => {
  const store=createBrowserClipboardStore(), context={};
  const text=value=>({entries:[{mimeType:'text/plain',text:value}]});
  store.write(context,[text('preserved')]);
  const invalid=[null,{},Array(17).fill(text('x')),[{entries:[]}],
    [{entries:[{mimeType:'text/plain',text:'x',base64:'eA=='}]}],
    [{entries:[{mimeType:'text/plain',text:'a'},{mimeType:'TEXT/PLAIN',text:'b'}]}],
    [{entries:[{mimeType:'invalid',text:'x'}]}],
    [{entries:[{mimeType:'image/png',base64:'%%%'}]}],
    [{entries:[{mimeType:'image/png',base64:'Zh=='}]}],
    [text('x'.repeat(1024*1024+1))],
    [text('😀'.repeat(262145))],
    [text('valid first'),{entries:[{mimeType:'text/plain',text:null}]}],
  ];
  for(const items of invalid){assert.throws(()=>store.write(context,items));assert.equal(store.readText(context),'preserved');}
  assert.equal(store.write(context,[text('x'.repeat(1024*1024))]).bytes,1024*1024);
  store.write(context,[{entries:[{mimeType:'text/plain',base64:Buffer.from('Encoded 😀').toString('base64')}]}]);
  assert.equal(store.readText(context),'Encoded 😀');
});

test('macOS Meta+A carries the native select-all command while other keys retain normal dispatch', async () => {
  for (const key of ['Meta+A','Meta+z']) {
    const f=fixture(), events=[];
    f.page.pptrPage.keyboard={down:async key=>events.push(['down',key]),up:async key=>events.push(['up',key]),
      press:async(key,options)=>events.push(['press',key,options])};
    await createLocatorTool({zod,parseKey}).handler({page:f.page,params:{query:{css:'button'},action:'press',key,timeout:1000}},
      {appendResponseLine:()=>{},attachWaitForResult:()=>{}});
    assert.deepEqual(events[1][2],process.platform==='darwin'&&key==='Meta+A'?{commands:['selectAll']}:undefined);
    assert.deepEqual(events[0],['down','Meta']);assert.deepEqual(events[2],['up','Meta']);
  }
});
