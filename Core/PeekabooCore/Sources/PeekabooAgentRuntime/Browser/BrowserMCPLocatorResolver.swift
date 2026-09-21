/// Provider-side locator resolution. Handles stay owned until the operation completes.
enum BrowserMCPLocatorResolver {
    static let source = #"""
    async function resolveOnce(page, params, operation, collection = false) {
      const owned = [];
      const connected = [];
      let framesVisible = true;
      const hasVisibility = query => 'visible' in query ||
        [query.has, query.hasNot, query.and, query.or].some(child => child && hasVisibility(child));
      const checksVisibility = (params.fields ?? []).includes('visible') ||
        ['visible', 'hidden'].includes(params.waitState) || [
        params.query, ...(params.within ?? []).map(scope => scope.frame ?? scope.shadow ?? scope),
      ].some(hasVisibility);
      const own = handle => { owned.push(handle); return handle; };
      const select = async (root, query, collection = false) => {
        const roleMatches = [];
        const roleRanges = {};
        const roleQueries = new Map();
        const collectRoles = query => {
          if ('role' in query) roleQueries.set(JSON.stringify([query.name ?? null, query.role]), query);
          for (const child of [query.has, query.hasNot, query.and, query.or]) {
            if (child) collectRoles(child);
          }
        };
        collectRoles(query);
        const rootElement = root.asElement();
        let loadingTree = null;
        if (roleQueries.size && await rootElement.evaluate(node =>
          ['loading', 'interactive'].includes((node.ownerDocument ?? node).readyState))) {
          // queryAXTree waits for loading to finish; the full tree already contains
          // computed names for the currently available nodes.
          loadingTree = (await rootElement.client.send('Accessibility.getFullAXTree', {
            frameId: rootElement.frame._id,
          })).nodes;
        }
        for (const [key, roleQuery] of roleQueries) {
          const start = roleMatches.length;
          const element = root.asElement();
          if (loadingTree || typeof roleQuery.name === 'object') {
            const nodes = loadingTree ?? (await element.client.send('Accessibility.queryAXTree', {
              objectId: element.id, role: roleQuery.role,
            })).nodes;
            if (!loadingTree && nodes.length > 10000) {
              throw new Error('Role query exceeds 10000 candidates; narrow the scope');
            }
            for (const node of nodes) {
              if (node.ignored || !node.role || ['StaticText', 'InlineTextBox'].includes(node.role.value)) continue;
              if (node.role.value !== roleQuery.role) continue;
              const name = node.name?.value ?? '';
              const matches = roleQuery.name === undefined || (typeof roleQuery.name === 'string' ?
                name === roleQuery.name : new RegExp(roleQuery.name.regex, roleQuery.name.flags ?? '').test(name));
              if (matches) {
                roleMatches.push(own(await element.realm.adoptBackendNode(node.backendDOMNodeId)));
                if (roleMatches.length > 10000) {
                  throw new Error('Role query exceeds 10000 candidates; narrow the scope');
                }
              }
            }
          } else {
            for await (const candidate of element.queryAXTree(roleQuery.name, roleQuery.role)) {
              roleMatches.push(own(candidate));
              if (roleMatches.length > 10000) throw new Error('Role query exceeds 10000 candidates; narrow the scope');
            }
          }
          roleRanges[key] = [start, roleMatches.length, loadingTree !== null];
        }
        const handle = own(await root.evaluateHandle(
          (scope, query, framesVisible, roleRanges, collection, ...roleMatches) => {
          const rootScope = scope;
          const normalize = value => String(value ?? '').replace(/\s+/g, ' ').trim();
          const containsText = (node, value) =>
            typeof value === 'object' ? regexMatches(textFor(node), value) :
            normalize(textFor(node)).toLowerCase().includes(normalize(value).toLowerCase());
          const regexMatches = (actual, matcher) => new RegExp(matcher.regex, matcher.flags ?? '').test(actual);
          const textCache = new WeakMap();
          const textFor = node => {
            if (node.nodeType === 8 || ['SCRIPT', 'STYLE', 'HEAD'].includes(node.tagName)) return '';
            if (node.nodeType === 3) return node.textContent ?? '';
            if (textCache.has(node)) return textCache.get(node);
            const value = node.tagName === 'INPUT' && ['button', 'submit'].includes(node.type) ? node.value :
              node.childNodes ? [...node.childNodes].map(textFor).join('') : node.textContent ?? '';
            textCache.set(node, value);
            return value;
          };
          const textMatches = (node, query) => {
            if (['SCRIPT', 'STYLE', 'HEAD'].includes(node.tagName) || node.closest?.('script,style,head')) return false;
            if (typeof query.text === 'object') return regexMatches(textFor(node), query.text);
            const actual = normalize(textFor(node)), expected = normalize(query.text);
            return query.exact ? actual === expected : actual.toLowerCase().includes(expected.toLowerCase());
          };
          let descendantChecks = 0;
          const hasDescendant = (node, query) => {
            if (++descendantChecks > 10000) {
              throw new Error('Descendant filter exceeds 10000 checks; narrow the outer selector');
            }
            return find(node, query).length > 0;
          };
          const find = (scope, query) => {
            let matches;
            if ('role' in query) {
              const [start, end, fullTree] = roleRanges[JSON.stringify([query.name ?? null, query.role])];
              const contains = node => {
                for (let current = node; current; current = current.parentNode ?? current.getRootNode()?.host) {
                  if (current === scope) return true;
                }
                return false;
              };
              matches = roleMatches.slice(start, end).filter(node => node !== scope &&
                (scope === rootScope ? (!fullTree || contains(node)) : scope.contains(node)));
            } else if ('css' in query) {
              matches = [...scope.querySelectorAll(query.css)];
            } else if ('text' in query) {
              matches = [...scope.querySelectorAll('*')].filter(node => textMatches(node, query) &&
                ![...(node.children ?? [])].some(child => textMatches(child, query)));
            } else if ('label' in query) {
              matches = [...scope.querySelectorAll(
                'input,textarea,select,button,meter,output,progress,[aria-label],[aria-labelledby]'
              )].filter(node => {
                const labelText = current => current === node ? '' : current.nodeType === 3 ? current.textContent :
                  [...(current.childNodes ?? [])].map(labelText).join('');
                let names = [...(node.labels ?? [])].map(label => labelText(label));
                const aria = node.getAttribute('aria-label');
                if (aria) names = [aria];
                const ids = node.getAttribute('aria-labelledby');
                if (ids) {
                  const labels = ids.split(/\s+/).map(id => node.getRootNode().getElementById(id)).filter(Boolean);
                  if (labels.length) names = [labels.map(label => label.textContent ?? '').join(' ')];
                }
                return typeof query.label === 'object' ? names.some(name => regexMatches(name, query.label)) :
              names.map(normalize).includes(normalize(query.label));
              });
            } else {
              const attribute = 'placeholder' in query ? 'placeholder' : 'data-testid';
              const value = query.placeholder ?? query.testId;
              matches = [...scope.querySelectorAll('[' + attribute + ']')]
                .filter(node => typeof value === 'object' ? regexMatches(node.getAttribute(attribute), value) :
                  node.getAttribute(attribute) === value);
            }
            if ('and' in query) {
              const other = new Set(find(scope, query.and));
              matches = matches.filter(node => other.has(node));
            } else if ('or' in query) {
              matches = [...new Set([...matches, ...find(scope, query.or)])];
              matches.sort((left, right) => left === right ? 0 :
                left.compareDocumentPosition(right) & 2 ? 1 : -1);
            }
            if ('hasText' in query) {
              matches = matches.filter(node => containsText(node, query.hasText));
            }
            if ('hasNotText' in query) {
              matches = matches.filter(node => !containsText(node, query.hasNotText));
            }
            if ('has' in query) matches = matches.filter(node => hasDescendant(node, query.has));
            if ('hasNot' in query) matches = matches.filter(node => !hasDescendant(node, query.hasNot));
            if ('visible' in query) {
              matches = matches.filter(node => {
                const bounds = node.getBoundingClientRect();
                const visible = framesVisible && node.checkVisibility({visibilityProperty: true}) &&
                  bounds.width > 0 && bounds.height > 0;
                return visible === query.visible;
              });
            }
            if ('nth' in query) {
              const selected = matches[query.nth === -1 ? matches.length - 1 : query.nth];
              matches = selected ? [selected] : [];
            }
            return matches;
          };
          const matches = find(scope, query);
          if (!collection && matches.length !== 1) {
            throw new Error('Locator requires exactly one match; found ' + matches.length);
          }
          if (matches.some(node => !node.isConnected)) throw new Error('Locator element is detached');
          return collection ? matches : matches[0];
        }, query, framesVisible, roleRanges, collection, ...roleMatches));
        if (collection) return handle;
        const element = handle.asElement();
        if (!element) throw new Error('Locator did not resolve an element');
        connected.push(element);
        return element;
      };
      try {
        let root = own(await page.pptrPage.mainFrame().evaluateHandle(() => document));
        for (const scope of params.within ?? []) {
          const element = await select(root, scope.frame ?? scope.shadow ?? scope);
          if ('frame' in scope) {
            if (!await element.evaluate(node => ['IFRAME', 'FRAME'].includes(node.tagName))) {
              throw new Error('Frame locator did not select a frame element');
            }
            if (checksVisibility) {
              framesVisible = framesVisible && await element.evaluate(node => {
                const bounds = node.getBoundingClientRect();
                return node.checkVisibility({visibilityProperty: true}) && bounds.width > 0 && bounds.height > 0;
              });
            }
            const frame = await element.contentFrame();
            if (!frame) throw new Error('Frame locator is unavailable');
            root = own(await frame.evaluateHandle(() => document));
          } else if ('shadow' in scope) {
            root = own(await element.evaluateHandle(node => {
              if (!node.shadowRoot) throw new Error('Locator has no accessible open shadow root');
              return node.shadowRoot;
            }));
          } else {
            root = element;
          }
        }
        const element = await select(root, params.query, collection);
        for (const ancestor of connected) {
          if (!await ancestor.evaluate(node => node.isConnected)) {
            throw new Error('Locator scope detached before operation');
          }
        }
        return await operation(element, framesVisible);
      } finally {
        // Release every handle even when one disposal fails; preserve the operation's error.
        await Promise.allSettled(owned.reverse().map(handle => Promise.resolve().then(() => handle.dispose())));
      }
    }
    export async function withLocator(page, params, operation) {
      const deadline = performance.now() + (params.timeout ?? 5000);
      let dispatched = false;
      while (performance.now() < deadline) {
        try {
          return await resolveOnce(page, params, (element, framesVisible) => {
            const remaining = Math.floor(deadline - performance.now());
            if (remaining < 1) throw new Error('Locator presence wait timed out before input');
            dispatched = true;
            return operation(element, remaining, framesVisible);
          });
        } catch (error) {
          // Only a zero-match resolution is retryable, never an operation or ambiguous target.
          if (dispatched || error.message !== 'Locator requires exactly one match; found 0') throw error;
          const remaining = deadline - performance.now();
          if (remaining <= 0) break;
          await new Promise(resolve => setTimeout(resolve, Math.min(100, remaining)));
        }
      }
      throw new Error('Locator presence wait timed out before input');
    }
    async function checkedState(element) {
      return element.evaluate(node => {
        if (!node.isConnected) throw new Error('Checked target is detached');
        const native = node.tagName === 'INPUT' && ['checkbox', 'radio'].includes(node.type);
        const role = native ? node.type : node.getAttribute('role');
        if (!['checkbox', 'radio', 'switch'].includes(role)) {
          throw new Error('Check/uncheck requires a checkbox, radio or switch');
        }
        const aria = node.getAttribute('aria-checked');
        const checked = native ? node.checked : aria === 'true' ? true : aria === 'false' ? false : null;
        const mixed = role === 'checkbox' && (native ? node.indeterminate : aria === 'mixed');
        if (checked === null && !mixed) {
          throw new Error('Check/uncheck requires an unambiguous boolean checked state');
        }
        return {checked, mixed, role, disabled: node.matches(':disabled') || !!node.closest('[aria-disabled="true"]')};
      });
    }
    async function setChecked(element, locator, desired) {
      const before = await checkedState(element);
      if (before.checked === desired && !before.mixed) return;
      if (before.disabled) throw new Error('Checked target is disabled');
      if (before.role === 'radio' && !desired) throw new Error('Cannot uncheck a selected radio by clicking it');
      await locator.click();
      let after = await checkedState(element);
      // A mixed checkbox can settle on the opposite boolean state after its first click.
      if (before.mixed && !after.mixed && after.checked !== desired && !after.disabled) {
        await locator.click();
        after = await checkedState(element);
      }
      if (after.mixed || after.checked !== desired) {
        throw new Error('Click did not produce the requested checked state; do not replay');
      }
    }
    async function selectOptions(element, options) {
      const values = Array.isArray(options) ? options : [options];
      const descriptors = values.map(value => typeof value === 'string' ? {value} : value);
      await element.evaluate((node, requested) => {
        if (node.tagName !== 'SELECT' || !node.isConnected || node.matches(':disabled')) {
          throw new Error('Target must be a connected enabled native select');
        }
        const all = Array.from(node.options);
        const selected = requested.map(query => {
          const matches = all.filter(option => Object.entries(query).every(([key, value]) => option[key] === value));
          if (matches.length !== 1) throw new Error('Option descriptor must match exactly one option');
          if (matches[0].matches(':disabled')) throw new Error('Requested option is disabled');
          return matches[0];
        });
        const desired = new Set(selected);
        if (desired.size !== selected.length) throw new Error('Option descriptors overlap');
        if (!node.multiple && desired.size > 1) throw new Error('Multiple options require a multiple select');
        for (const option of all) option.selected = desired.has(option);
        if (!desired.size) node.selectedIndex = -1;
        const EventClass = node.ownerDocument.defaultView.Event;
        node.dispatchEvent(new EventClass('input', {bubbles: true}));
        node.dispatchEvent(new EventClass('change', {bubbles: true}));
        const actual = Array.from(node.selectedOptions);
        if (!node.isConnected || actual.length !== desired.size || actual.some(option => !desired.has(option))) {
          throw new Error('Selection changed during event handling; inspect before retrying');
        }
      }, descriptors);
    }
    async function withModifiers(keyboard, modifiers, operation) {
      const attempted = [];
      let failure;
      try {
        for (const modifier of modifiers) {
          // A failed transport reply may still have delivered keydown.
          attempted.push(modifier);
          await keyboard.down(modifier);
        }
        await operation();
      } catch (error) { failure = error; }
      for (const modifier of attempted.reverse()) {
        try { await keyboard.up(modifier); }
        catch (error) { failure ??= error; }
      }
      if (failure) throw failure;
    }
    export async function waitLocator(page, params) {
      const deadline = performance.now() + (params.timeout ?? 5000);
      while (performance.now() < deadline) {
        const result = await resolveOnce(page, params, (handle, framesVisible) =>
          handle.evaluate((matches, framesVisible, state) => {
            if (matches.length > 1) throw new Error('Locator requires at most one match; found ' + matches.length);
            if (matches.some(node => !node.isConnected)) throw new Error('Locator detached during state check');
            const node = matches[0];
            const bounds = node?.getBoundingClientRect();
            const visible = !!node && framesVisible && node.checkVisibility({visibilityProperty: true}) &&
              bounds.width > 0 && bounds.height > 0;
            const satisfied = state === 'attached' ? !!node : state === 'detached' ? !node :
              state === 'visible' ? visible : !visible;
            return satisfied ? {count: matches.length, records: [], omitted: matches.length, state,
              scope: 'Fresh locator matches; frame and shadow scopes resolved explicitly'} : null;
          }, framesVisible, params.waitState), true);
        if (performance.now() >= deadline) break;
        if (result) return result;
        await new Promise(resolve => setTimeout(resolve, Math.min(100, deadline - performance.now())));
      }
      throw new Error('Locator state wait timed out: ' + params.waitState);
    }

    export async function readLocator(page, params) {
      const read = (handle, framesVisible) => handle.evaluate((value, params, framesVisible) => {
        const matches = Array.isArray(value) ? value : [value];
        if (matches.some(node => !node.isConnected)) throw new Error('Locator element detached before read');
        const config = {...params, operation: params.action};
        const records = [];
        const isEnabled = node => {
          const parent = element => element.parentElement ?? element.getRootNode()?.host ?? null;
          const nativeDisabled = element => ['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'OPTION', 'OPTGROUP']
            .includes(element.tagName) && element.matches(':disabled');
          const supported = new Set(('application button composite gridcell group input link menuitem ' +
            'scrollbar separator tab ' +
            'checkbox columnheader combobox grid listbox menu menubar ' +
              'menuitemcheckbox menuitemradio option radio radiogroup ' +
            'row rowheader searchbox select slider spinbutton switch tablist ' +
              'textbox toolbar tree treegrid treeitem').split(' '));
          const valid = new Set(('alert alertdialog application article banner blockquote button caption ' +
            'cell checkbox code ' +
            'columnheader combobox complementary contentinfo definition deletion ' +
              'dialog directory document emphasis feed figure ' +
            'form generic grid gridcell group heading img insertion link list ' +
              'listbox listitem log main mark marquee math meter ' +
            'menu menubar menuitem menuitemcheckbox menuitemradio navigation none ' +
              'note option paragraph presentation progressbar ' +
            'radio radiogroup region row rowgroup rowheader scrollbar search ' +
              'searchbox separator slider spinbutton status strong ' +
            'subscript superscript switch tab table tablist tabpanel term textbox ' +
              'time timer toolbar tooltip tree treegrid treeitem')
            .split(' '));
          const explicit = element => (element.getAttribute('role') ?? '').split(' ')
            .map(role => role.trim()).find(role => valid.has(role)) ?? '';
          const closest = (element, tag) => {
            for (let current = parent(element); current; current = parent(current)) {
              if (current.tagName === tag) return current;
            }
            return null;
          };
          const conflict = (element, role) => {
            const global = ('aria-atomic aria-busy aria-controls aria-current aria-describedby ' +
              'aria-details aria-dropeffect ' +
              'aria-flowto aria-grabbed aria-hidden aria-keyshortcuts aria-live ' +
                'aria-owns aria-relevant aria-roledescription')
              .split(' ');
            const labelProhibited = ['caption', 'code', 'deletion', 'emphasis', 'generic', 'insertion', 'paragraph',
              'presentation', 'strong', 'subscript', 'superscript'];
            if (!labelProhibited.includes(role)) global.push('aria-label', 'aria-labelledby');
            if (global.some(attribute => element.hasAttribute(attribute))) return true;
            if (nativeDisabled(element)) return false;
            const tag = element.tagName;
            const tabIndex = element.getAttribute('tabindex');
            return (tabIndex !== null && !Number.isNaN(Number(tabIndex))) ||
              ['BUTTON', 'DETAILS', 'SELECT', 'TEXTAREA'].includes(tag) ||
              (['A', 'AREA'].includes(tag) && element.hasAttribute('href')) || (tag === 'INPUT' && !element.hidden);
          };
          const implicit = element => {
            const tag = element.tagName;
            if (['A', 'AREA'].includes(tag)) return element.hasAttribute('href') ? 'link' : '';
            if (tag === 'INPUT') return element.type === 'hidden' ? '' : 'textbox';
            if (tag === 'TD') {
              const tableRole = explicit(closest(element, 'TABLE') ?? element);
              return ['grid', 'treegrid'].includes(tableRole) ? 'gridcell' : '';
            }
            if (tag === 'TH') {
              if (['col', 'colgroup', 'row', 'rowgroup'].includes(element.getAttribute('scope'))) {
                return 'columnheader';
              }
              const table = closest(element, 'TABLE');
              if (!element.nextElementSibling && !element.previousElementSibling &&
                  element.parentElement?.tagName === 'TR' &&
                  table && table.rows.length <= 1) return '';
              return 'columnheader';
            }
            return {BUTTON: 'button', DATALIST: 'listbox', DETAILS: 'group', FIELDSET: 'group', HR: 'separator',
              OPTGROUP: 'group', OPTION: 'option', SELECT: 'combobox', TEXTAREA: 'textbox', TR: 'row'}[tag] ?? '';
          };
          const inheritedPresentation = element => {
            const parents = {TBODY: ['TABLE'], TD: ['TR'], TFOOT: ['TABLE'], TH: ['TR'], THEAD: ['TABLE'],
              TR: ['THEAD', 'TBODY', 'TFOOT', 'TABLE']};
            for (let current = element; current;) {
              const ancestor = parent(current);
              if (!ancestor || !parents[current.tagName]?.includes(ancestor.tagName)) break;
              if (['none', 'presentation'].includes(explicit(ancestor)) && !conflict(ancestor, explicit(ancestor))) {
                return true;
              }
              current = ancestor;
            }
            return false;
          };
          if (nativeDisabled(node)) return false;
          let role = explicit(node);
          if (!role || (['none', 'presentation'].includes(role) && conflict(node, implicit(node)))) {
            role = inheritedPresentation(node) ? '' : implicit(node);
          }
          if (!supported.has(role)) return true;
          for (let current = node; current; current = parent(current)) {
            const state = (current.getAttribute('aria-disabled') ?? '').toLowerCase();
            if (state === 'true') return false;
            if (state === 'false') return true;
          }
          return true;
        };
        const readers = {
          tag: node => node.tagName,
          text: node => String(node.innerText ?? node.textContent ?? ''),
          innerText: node => String(node.innerText ?? ''),
          textContent: node => String(node.textContent ?? ''),
          value: node => node.type === 'password' ? '[password value omitted]' : String(node.value ?? ''),
          href: node => typeof node.href === 'string' ? node.href : '',
          checked: node => typeof node.checked === 'boolean' ? node.checked : null,
          disabled: node => typeof node.disabled === 'boolean' ? node.disabled : null,
          enabled: isEnabled,
          visible: node => {
            const bounds = node.getBoundingClientRect();
            return framesVisible && node.checkVisibility({visibilityProperty: true}) &&
              bounds.width > 0 && bounds.height > 0;
          },
        };
        const clip = (value, limit) => {
          const last = value.charCodeAt(limit - 1);
          return value.slice(0, last >= 0xD800 && last <= 0xDBFF ? limit - 1 : limit);
        };
        const fitRecord = record => {
          while (JSON.stringify(record).length > 6000) {
            record.truncated = true;
            const field = Object.keys(record).filter(key => typeof record[key] === 'string' && record[key].length)
              .sort((a, b) => JSON.stringify(record[b]).length - JSON.stringify(record[a]).length)[0];
            if (!field) throw new Error('Requested field names exceed DOM record budget');
            const value = record[field];
            const target = JSON.stringify(value).length - (JSON.stringify(record).length - 6000);
            let low = 0, high = value.length;
            while (low < high) {
              const middle = Math.ceil((low + high) / 2);
              if (JSON.stringify(clip(value, middle)).length <= target) low = middle;
              else high = middle - 1;
            }
            record[field] = clip(value, low);
          }
        };
        let budget = 6000;
        if (config.operation !== 'count') {
          const start = config.offset ?? 0;
          for (const node of matches.slice(start, start + (config.limit ?? 50))) {
            const record = {truncated: false};
            for (const field of config.fields ?? ['tag', 'text', 'value', 'checked', 'disabled']) {
              let value = field.startsWith('attr:') ?
                (node.type === 'password' && field.slice(5).toLowerCase() === 'value' ?
                  '[password value omitted]' : node.getAttribute(field.slice(5))) : readers[field](node);
              if (typeof value === 'string' && value.length > 1000) {
                value = clip(value, 1000);
                record.truncated = true;
              }
              record[field] = value;
            }
            fitRecord(record);
            const size = JSON.stringify(record).length;
            if (size > budget) break;
            budget -= size;
            records.push(record);
          }
        }
        const offset = config.offset ?? 0;
        const nextOffset = offset + records.length < matches.length ? offset + records.length : null;
        return {count: matches.length, records, omitted: matches.length - records.length,
          ...(config.operation === 'read-all' ? {offset, nextOffset} : {}),
          scope: 'Fresh locator matches; frame and shadow scopes resolved explicitly'};
      }, params, framesVisible);
      return params.action === 'read' ? withLocator(page, params, (element, _, visible) => read(element, visible)) :
        resolveOnce(page, params, read, true);
    }

    export async function withExpectedNavigation(page, expected, action) {
      if (!expected) return action();
      const controller = new AbortController();
      const timeout = expected.timeout ?? 5000;
      let onCommit, commitTimer;
      const committed = expected.loadState === 'commit' ? new Promise((resolve, reject) => {
        onCommit = frame => { if (frame === page.mainFrame()) resolve(); };
        page.on('framenavigated', onCommit);
        commitTimer = setTimeout(() => reject(new Error('Navigation commit timed out')), timeout);
        controller.signal.addEventListener('abort', () => reject(controller.signal.reason), {once: true});
      }) : Promise.resolve();
      // Install both listeners before input. An empty lifecycle list alone can resolve
      // before Puppeteer updates the committed main-frame URL.
      const navigation = Promise.all([committed, page.waitForNavigation({
        timeout,
        waitUntil: expected.loadState === 'commit' ? [] :
          expected.loadState === 'networkidle' ? 'networkidle0' : expected.loadState ?? 'load',
        signal: controller.signal,
      })]).then(() => ({ok: true}), error => ({ok: false, error}));
      try {
        const result = await action();
        const outcome = await navigation;
        if (!outcome.ok) throw outcome.error ?? new Error('Navigation failed');
        const url = page.url();
        if (typeof expected.url === 'string' && url !== expected.url) {
          throw new Error('Navigation completed at an unexpected URL; do not replay the action');
        }
        if (expected.url && typeof expected.url === 'object' &&
            !new RegExp(expected.url.regex, expected.url.flags ?? '').test(url)) {
          throw new Error('Navigation completed at an unexpected URL; do not replay the action');
        }
        return result;
      } finally {
        controller.abort();
        if (onCommit) page.off('framenavigated', onCommit);
        clearTimeout(commitTimer);
        await navigation;
      }
    }

    export function createLocatorTool({zod, parseKey}) {
      const clipboard = createBrowserClipboardStore();
      const text = zod.string().min(1).max(1000);
      const regex = (maximum = 1000) => zod.object({
        regex: zod.string().max(maximum), flags: zod.string().max(8).optional(),
      })
        .strict().refine(value => {
          try { new RegExp(value.regex, value.flags ?? ''); return true; }
          catch { return false; }
        }, 'Invalid JavaScript regular expression or flags');
      const matcher = () => zod.union([zod.string().max(1000), regex()]);
      const selectorMatcher = () => zod.union([text, regex()]);
      const createQuery = (depth, allowRole) => {
        const refinements = {
          hasText: matcher().optional(),
          hasNotText: matcher().optional(),
          visible: zod.boolean().optional(),
          nth: zod.number().int().min(-1).max(Number.MAX_SAFE_INTEGER).optional(),
        };
        const child = depth > 0 ? createQuery(depth - 1, allowRole).optional() : null;
        const filters = {...refinements, ...(child ? {has: child, hasNot: child, and: child, or: child} : {})};
        return zod.union([
          ...['css', 'testId'].map(key => zod.object({[key]: text, ...filters}).strict()),
          ...['label', 'placeholder'].map(key => zod.object({[key]: selectorMatcher(), ...filters}).strict()),
          zod.object({text: selectorMatcher(), exact: zod.boolean().optional(), ...filters}).strict(),
          ...(allowRole ? [
            zod.object({role: text, name: matcher().optional(), ...filters}).strict(),
          ] : []),
        ]).refine(value => !('and' in value && 'or' in value), 'Use one and/or refinement per query');
      };
      const query = createQuery(3, true);
      const scope = zod.union([query, zod.object({frame: query}).strict(), zod.object({shadow: query}).strict()]);
      const fieldPattern = new RegExp(
        '^(?:tag|text|innerText|textContent|value|href|checked|disabled|visible|enabled|' +
        'attr:[A-Za-z_][A-Za-z0-9_.:-]{0,127})$');
      const optionText = zod.string().max(1000);
      const option = zod.union([optionText, zod.object({
        value: optionText.optional(), label: optionText.optional(),
        index: zod.number().int().min(0).max(Number.MAX_SAFE_INTEGER).optional(),
      }).strict().refine(value => Object.keys(value).length > 0, 'Option descriptor cannot be empty')]);
      return {
        name: 'peekaboo_locator_action',
        description: 'Resolve fresh DOM/role locators to read bounded fields or perform exact input. ' +
          'Select uses native option state and synthetic input/change events.',
        pageScoped: true,
        annotations: {category: 'input', readOnlyHint: false},
        blockedByDialog: true,
        verifyFilesSchema: {},
        schema: {
          query: query.optional(),
          items: zod.array(zod.object({
            presentationStyle: zod.enum(['unspecified', 'inline', 'attachment']).optional(),
            entries: zod.array(zod.object({
              mimeType: zod.string().min(3).max(255),
              text: zod.string().max(2097152).optional(),
              base64: zod.string().max(2097152).optional(),
            }).strict()).min(1).max(16),
          }).strict()).max(16).optional(),
          within: zod.array(scope).max(8).optional(),
          action: zod.enum(['click', 'dblclick', 'fill', 'hover', 'type', 'press', 'check', 'uncheck', 'select',
            'read', 'read-all', 'count', 'wait', 'paste', 'copy', 'clipboard-read', 'clipboard-write']),
          waitState: zod.enum(['attached', 'detached', 'visible', 'hidden']).optional(),
          fields: zod.array(zod.string().regex(fieldPattern))
            .min(1).max(12)
            .refine(fields => new Set(fields).size === fields.length, 'Fields must be unique').optional(),
          offset: zod.number().int().min(0).max(Number.MAX_SAFE_INTEGER).optional(),
          limit: zod.number().int().min(1).max(50).optional(),
          button: zod.enum(['left', 'right', 'middle']).optional(),
          modifiers: zod.array(zod.enum(['Alt', 'Control', 'Meta', 'Shift', 'ControlOrMeta'])).max(4).optional(),
          options: zod.union([option, zod.array(option).max(50)]).optional(),
          key: zod.string().min(1).max(100).optional(),
          value: zod.string().max(100000).optional(),
          timeout: zod.number().int().min(1).max(20000).optional(),
          download: zod.object({
            state: zod.enum(['started', 'completed']).optional(),
            timeout: zod.number().int().min(1).max(20000).optional(),
          }).strict().optional(),
          navigation: zod.object({
            url: zod.union([zod.string().min(1).max(8192), regex(8192)]).optional(),
            loadState: zod.enum(['commit', 'domcontentloaded', 'load', 'networkidle']).optional(),
            timeout: zod.number().int().min(1).max(20000).optional(),
          }).strict().optional(),
          includeSnapshot: zod.boolean().optional(),
        },
        async handler(request, response) {
          const params = request.params;
          if (['clipboard-read', 'clipboard-write'].includes(params.action)) {
            if (Object.keys(params).some(key => !['action', 'items', 'pageId'].includes(key)) ||
                (params.action === 'clipboard-write') !== (params.items !== undefined)) {
              throw new Error('Clipboard read takes no options; clipboard write requires only items');
            }
            const context = request.page.pptrPage.browserContext();
            const result = params.action === 'clipboard-write' ? clipboard.write(context, params.items) :
              {items: clipboard.read(context)};
            response.appendResponseLine(JSON.stringify({clipboard: result}));
            return;
          }
          if (!params.query) throw new Error('Locator action requires a query');
          if (params.items !== undefined) throw new Error('Only clipboard-write accepts items');
          if ((['fill', 'type'].includes(params.action)) !== (params.value !== undefined)) {
            throw new Error('Only fill and type require a value');
          }
          if ((params.action === 'press') !== (params.key !== undefined)) {
            throw new Error('Only press requires a key');
          }
          if ((params.action === 'select') !== (params.options !== undefined)) {
            throw new Error('Only select requires options');
          }
          const isClick = ['click', 'dblclick'].includes(params.action);
          if (!isClick && (params.button !== undefined || params.modifiers !== undefined)) {
            throw new Error('Only click and dblclick accept button or modifiers');
          }
          const clickModifiers = (params.modifiers ?? []).map(key =>
            key === 'ControlOrMeta' ? (process.platform === 'darwin' ? 'Meta' : 'Control') : key);
          if (new Set(clickModifiers).size !== clickModifiers.length) {
            throw new Error('Click modifiers must be unique after platform resolution');
          }
          if ((params.action === 'wait') !== (params.waitState !== undefined)) {
            throw new Error('Only wait requires waitState');
          }
          const isRead = ['read', 'read-all', 'count', 'wait'].includes(params.action);
          if ((!['read', 'read-all'].includes(params.action)) && params.fields !== undefined) {
            throw new Error('Fields require read or read-all');
          }
          if (params.action !== 'read-all' && (params.offset !== undefined || params.limit !== undefined)) {
            throw new Error('Offset and limit require read-all');
          }
          if (isRead && (params.navigation !== undefined || params.download !== undefined)) {
            throw new Error('Expected navigation or download requires input');
          }
          if (params.navigation !== undefined && params.download !== undefined) {
            throw new Error('Expected navigation and download are mutually exclusive');
          }
          if (isRead) {
            if (params.includeSnapshot) throw new Error('Locator reads do not include a duplicate snapshot');
            response.appendResponseLine(JSON.stringify(await (params.action === 'wait' ?
              waitLocator(request.page, params) : readLocator(request.page, params))));
            return;
          }
          let keys;
          if (params.action === 'press') {
            try { keys = parseKey(params.key); }
            catch { throw new Error('Invalid key combination: ' + params.key); }
            if (keys.slice(1).some(key => !['Control', 'Shift', 'Alt', 'Meta'].includes(key))) {
              throw new Error('Key combination prefixes must be Control, Shift, Alt or Meta');
            }
          }
          const result = await withLocator(request.page, params, async (element, remaining) => {
            const locator = element.asLocator().setTimeout(remaining);
            const performInput = async () => {
              if (isClick) {
                const options = {};
                if (params.action === 'dblclick') options.count = 2;
                if (params.button !== undefined) options.button = params.button;
                await withModifiers(request.page.pptrPage.keyboard, clickModifiers,
                  () => locator.click(Object.keys(options).length ? options : undefined));
              }
              else if (params.action === 'select') await selectOptions(element, params.options);
              else if (params.action === 'copy') {
                clipboard.write(request.page.pptrPage.browserContext(), await copyBrowserSelection(element));
              }
              else if (params.action === 'paste') {
                await pasteBrowserClipboard(element, request.page.pptrPage.keyboard,
                  clipboard.read(request.page.pptrPage.browserContext()));
              }
              else if (params.action === 'fill') await locator.fill(params.value);
              else if (params.action === 'hover') await locator.hover();
              else if (params.action === 'check' || params.action === 'uncheck') {
                await setChecked(element, locator, params.action === 'check');
              }
              else {
                if (params.action === 'type') {
                  const editable = await element.evaluate(node => {
                    const textInput = node.tagName === 'INPUT' &&
                      ['text', 'search', 'url', 'tel', 'email', 'password', 'number'].includes(node.type);
                    return (textInput || node.tagName === 'TEXTAREA' || node.isContentEditable) &&
                      !node.matches(':disabled') && !node.readOnly;
                  });
                  if (!editable) throw new Error('Locator type requires an enabled editable element');
                }
                if (await element.evaluate(node => node.matches(':disabled'))) {
                  throw new Error('Locator keyboard target is disabled');
                }
                await element.focus();
                if (!await element.evaluate(node => node.isConnected && node.getRootNode().activeElement === node)) {
                  throw new Error('Locator keyboard action could not focus the target');
                }
                if (params.action === 'type') await element.type(params.value);
                else {
                  const keyboard = request.page.pptrPage.keyboard;
                  const [key, ...modifiers] = keys;
                  const selectAll = process.platform === 'darwin' && modifiers.length === 1 &&
                    modifiers[0] === 'Meta' && key.toLowerCase() === 'a';
                  await withModifiers(keyboard, modifiers, () => selectAll ?
                    keyboard.press(key, {commands: ['selectAll']}) : keyboard.press(key));
                }
              }
            };
            if (params.download) {
              const download = await withExpectedDownload(request.page.pptrPage, params.download, performInput);
              return {download, dialogHandled: false};
            }
            if (params.navigation) {
              await withExpectedNavigation(request.page.pptrPage, params.navigation, performInput);
              return {navigatedToUrl: request.page.pptrPage.url(), dialogHandled: false};
            }
            return request.page.waitForEventsAfterAction(performInput);
          });
          response.appendResponseLine('Locator ' + params.action + ' completed.');
          if (result.download) response.appendResponseLine(JSON.stringify({download: result.download}));
          response.attachWaitForResult(result);
          if (params.includeSnapshot) response.includeSnapshot();
        },
      };
    }
    """#
}
