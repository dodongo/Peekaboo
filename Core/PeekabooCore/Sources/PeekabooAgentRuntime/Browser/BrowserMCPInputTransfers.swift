/// Provider-session clipboard and download operations; no shared OS clipboard or download-setting changes.
enum BrowserMCPInputTransfers {
    static let source = #"""
    // Scoped to provider-owned browser contexts, never navigator.clipboard or the OS pasteboard.
    export function createBrowserClipboardStore() {
      const contexts = new WeakMap();
      const maximumBytes = 1024 * 1024;
      const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
      const validate = items => {
        if (!Array.isArray(items) || items.length > 16) throw new Error('Clipboard accepts 0..16 items');
        let bytes = 0, entries = 0;
        const result = items.map(item => {
          if (!object(item) || Object.keys(item).some(key => !['entries', 'presentationStyle'].includes(key)) ||
              !Array.isArray(item.entries) || !item.entries.length || item.entries.length > 16 ||
              (item.presentationStyle !== undefined &&
               !['unspecified', 'inline', 'attachment'].includes(item.presentationStyle))) {
            throw new Error('Invalid clipboard item');
          }
          const types = new Set();
          const values = item.entries.map(entry => {
            if (++entries > 64 || !object(entry) ||
                Object.keys(entry).some(key => !['mimeType', 'text', 'base64'].includes(key)) ||
                typeof entry.mimeType !== 'string' || entry.mimeType.length > 255 ||
                !/^[^\s/]+\/[^\s/]+$/.test(entry.mimeType) ||
                types.has(entry.mimeType.toLowerCase()) ||
                (entry.text === undefined) === (entry.base64 === undefined)) {
              throw new Error('Invalid or duplicate clipboard MIME entry');
            }
            types.add(entry.mimeType.toLowerCase());
            const content = entry.text ?? entry.base64;
            if (typeof content !== 'string' || content.length > 2 * maximumBytes) {
              throw new Error('Invalid or oversized clipboard content');
            }
            if (entry.base64 !== undefined &&
                (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(content) ||
                 Buffer.from(content, 'base64').toString('base64') !== content)) {
              throw new Error('Clipboard binary content requires canonical base64');
            }
            bytes += entry.text !== undefined ? Buffer.byteLength(content, 'utf8') :
              Buffer.from(content, 'base64').length;
            if (bytes > maximumBytes) throw new Error('Clipboard content exceeds 1 MiB');
            return {...entry};
          });
          return {...item, entries: values};
        });
        return {items: result, bytes};
      };
      return {
        write(context, items) {
          const checked = validate(items);
          contexts.set(context, checked.items);
          return {itemCount: checked.items.length,
            entryCount: checked.items.reduce((sum, item) => sum + item.entries.length, 0), bytes: checked.bytes};
        },
        read(context) { return structuredClone(contexts.get(context) ?? []); },
        readText(context) {
          for (const item of contexts.get(context) ?? []) {
            const entry = item.entries.find(entry => entry.mimeType.toLowerCase() === 'text/plain');
            if (entry) return entry.text ?? Buffer.from(entry.base64, 'base64').toString('utf8');
          }
          return '';
        },
      };
    }
    export async function copyBrowserSelection(element) {
      return element.evaluate(node => {
        if (!node.isConnected) throw new Error('Clipboard copy target is detached');
        if (node.tagName === 'INPUT' && node.type === 'password') {
          throw new Error('Password controls do not expose copy contents');
        }
        let text, html;
        if (node.tagName === 'INPUT' || node.tagName === 'TEXTAREA') {
          if (node.getRootNode().activeElement !== node || !Number.isInteger(node.selectionStart) ||
              node.selectionStart === node.selectionEnd) throw new Error('No selection inside clipboard copy target');
          text = node.value.slice(node.selectionStart, node.selectionEnd);
        } else {
          const root = node.getRootNode();
          const selection = root.getSelection?.() ?? node.ownerDocument.getSelection();
          if (!selection || selection.isCollapsed || selection.rangeCount !== 1) {
            throw new Error('No single selection inside clipboard copy target');
          }
          const range = selection.getRangeAt(0);
          if (!node.contains(range.startContainer) || !node.contains(range.endContainer)) {
            throw new Error('Selection extends outside clipboard copy target');
          }
          text = selection.toString();
          const container = node.ownerDocument.createElement('div');
          container.append(range.cloneContents()); html = container.innerHTML;
        }
        const transfer = new DataTransfer();
        const useDefault = node.dispatchEvent(new ClipboardEvent('copy', {clipboardData: transfer,
          bubbles: true, cancelable: true, composed: true}));
        const entries = useDefault ? [{mimeType: 'text/plain', text},
          ...(html ? [{mimeType: 'text/html', text: html}] : [])] :
          Array.from(transfer.types).filter(type => type !== 'Files')
            .map(mimeType => ({mimeType, text: transfer.getData(mimeType)}));
        if (!entries.length) throw new Error('Copy handler supplied no clipboard entries');
        if (entries.length > 16 ||
            entries.reduce((size, entry) => size + new TextEncoder().encode(entry.text).length, 0) > 1048576) {
          throw new Error('Copied contents exceed clipboard bounds');
        }
        return [{entries}];
      });
    }
    export async function pasteBrowserClipboard(element, keyboard, items) {
      if (!items.length) throw new Error('Browser clipboard is empty');
      const entries = items.flatMap(item => item.entries);
      const plain = entries.find(entry => entry.mimeType.toLowerCase() === 'text/plain');
      const text = plain ? plain.text ?? Buffer.from(plain.base64, 'base64').toString('utf8') : '';
      await element.focus();
      const accepted = await element.evaluate((node, entries) => {
        if (!node.isConnected || node.getRootNode().activeElement !== node || node.matches(':disabled')) {
          throw new Error('Clipboard paste target could not receive focus');
        }
        const transfer = new DataTransfer(), textTypes = new Set();
        for (const entry of entries) {
          const type = entry.mimeType.toLowerCase();
          if ((entry.text !== undefined || type.startsWith('text/')) && textTypes.has(type)) continue;
          if (entry.text !== undefined) {
            transfer.setData(entry.mimeType, entry.text); textTypes.add(type);
          }
          else {
            const bytes = Uint8Array.from(atob(entry.base64), char => char.charCodeAt(0));
            if (entry.mimeType.toLowerCase().startsWith('text/')) {
              transfer.setData(entry.mimeType, new TextDecoder().decode(bytes)); textTypes.add(type);
            } else {
              transfer.items.add(new File([bytes], 'clipboard', {type: entry.mimeType}));
            }
          }
        }
        return node.dispatchEvent(new ClipboardEvent('paste', {clipboardData: transfer,
          bubbles: true, cancelable: true, composed: true}));
      }, entries);
      if (!accepted) return {handledByPage: true, insertedCharacters: 0};
      if (text) {
        const editable = await element.evaluate(node => {
          const textInput = node.tagName === 'INPUT' &&
            ['text', 'search', 'url', 'tel', 'email', 'password', 'number'].includes(node.type);
          return node.isConnected && node.getRootNode().activeElement === node &&
            (textInput || node.tagName === 'TEXTAREA' || node.isContentEditable) &&
            !node.matches(':disabled') && !node.readOnly;
        });
        if (!editable) throw new Error('Clipboard paste target changed or is not writable; paste was not replayed');
        await keyboard.sendCharacter(text);
      }
      return {handledByPage: false, insertedCharacters: Array.from(text).length};
    }
    export async function withExpectedDownload(page, expected, action) {
      const timeout = expected.timeout ?? 5000;
      if (!Number.isInteger(timeout) || timeout < 1 || timeout > 20000 ||
          !['started', 'completed'].includes(expected.state ?? 'completed')) {
        throw new Error('Invalid expected download state or timeout');
      }
      const session = await page.createCDPSession();
      let timer, receipt;
      let resolveDownload, rejectDownload;
      const pending = new Promise((resolve, reject) => {
        resolveDownload = resolve; rejectDownload = reject;
      });
      // An input failure can win the race; keep the event waiter observed until cleanup.
      pending.catch(() => {});
      const began = event => {
        if (receipt || !page.frames().some(frame => frame._id === event.frameId)) return;
        if (typeof event.guid !== 'string' || event.guid.length > 128 ||
            typeof event.url !== 'string' || event.url.length > 8192 ||
            typeof event.suggestedFilename !== 'string' || event.suggestedFilename.length > 1024) {
          rejectDownload(new Error('Download metadata exceeds receipt bounds')); return;
        }
        receipt = {state: 'started', guid: event.guid, url: event.url,
          suggestedFilename: event.suggestedFilename};
        if (expected.state === 'started') resolveDownload(receipt);
      };
      const progressed = event => {
        if (!receipt || event.guid !== receipt.guid) return;
        if (event.state === 'canceled') {
          rejectDownload(new Error('Expected download was canceled; input was not replayed'));
        }
        if (event.state === 'completed') {
          const bytes = event.receivedBytes;
          if (!Number.isFinite(bytes) || bytes < 0) {
            rejectDownload(new Error('Download returned invalid byte count')); return;
          }
          resolveDownload({...receipt, state: 'completed', receivedBytes: bytes});
        }
      };
      session.on('Page.downloadWillBegin', began);
      session.on('Page.downloadProgress', progressed);
      try {
        await session.send('Page.enable');
        timer = setTimeout(() =>
          rejectDownload(new Error('Expected download timed out; input was not replayed')), timeout);
        await action();
        return await pending;
      } finally {
        clearTimeout(timer);
        session.off('Page.downloadWillBegin', began);
        session.off('Page.downloadProgress', progressed);
        await session.detach().catch(() => {});
      }
    }
    """#
}
