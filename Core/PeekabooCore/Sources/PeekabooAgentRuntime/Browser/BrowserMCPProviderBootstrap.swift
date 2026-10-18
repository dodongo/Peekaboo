import Foundation

/// Embedded in both the CLI and GUI host so npm-distributed providers receive the same audited patch.
enum BrowserMCPProviderBootstrap {
    /// Keep this executable source covered by scripts/test-chrome-devtools-mcp-contract.mjs.
    static let source = #"""
    import {readFileSync, realpathSync} from 'node:fs';
    import {delimiter, dirname, join} from 'node:path';
    import {pathToFileURL} from 'node:url';
    import {register} from 'node:module';

    const candidates = (process.env.PATH ?? '').split(delimiter);
    let root;
    for (const directory of candidates) {
      if (!directory.endsWith('/node_modules/.bin')) continue;
      try {
        root = dirname(realpathSync(join(directory, '../chrome-devtools-mcp/package.json')));
        break;
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      }
    }
    if (!root) throw new Error('Peekaboo: pinned Chrome DevTools MCP package missing');
    const metadata = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    if (metadata.name !== 'chrome-devtools-mcp' || metadata.version !== '1.10.1') {
      throw new Error('Peekaboo: unexpected Chrome DevTools MCP package');
    }
    const entry = join(root, 'build/src/bin/chrome-devtools-mcp.js');
    const target = pathToFileURL(join(root, 'build/src/ToolHandler.js')).href;
    const browserTarget = pathToFileURL(join(root, 'build/src/BrowserManager.js')).href;
    const transportTarget = pathToFileURL(join(root, 'build/src/third_party/index.js')).href;
    const scriptTarget = pathToFileURL(join(root, 'build/src/tools/script.js')).href;
    const toolsTarget = pathToFileURL(join(root, 'build/src/tools/tools.js')).href;
    const snapshotTarget = pathToFileURL(join(root, 'build/src/tools/snapshot.js')).href;
    const networkTarget = pathToFileURL(join(root, 'build/src/tools/network.js')).href;
    const assetBundleSource = Buffer.from('__PEEKABOO_ASSET_BUNDLE_SOURCE__', 'base64').toString('utf8');
    const pageWaitSource = Buffer.from('__PEEKABOO_PAGE_WAIT_SOURCE__', 'base64').toString('utf8');
    const locatorSource = Buffer.from('__PEEKABOO_LOCATOR_SOURCE__', 'base64').toString('utf8');
    const loader = `
      import {createHash} from 'node:crypto';
      let target, browserTarget, transportTarget, toolsTarget, scriptTarget, snapshotTarget, networkTarget;
      let locatorSource, pageWaitSource, assetBundleSource;
      export function initialize(data) {
        ({target, browserTarget, transportTarget, toolsTarget, scriptTarget, snapshotTarget, networkTarget,
          locatorSource, pageWaitSource, assetBundleSource} = data);
      }
      export async function load(url, context, nextLoad) {
        const result = await nextLoad(url, context);
        if (url === networkTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'cbb58eac8cc58a27abb4912d77a4a06e1f60d3ae3f7cd8a46346e5c7985ec0dd') {
            throw new Error('Peekaboo: unaudited network tool');
          }
          const moduleURL = 'data:text/javascript,' + encodeURIComponent(assetBundleSource);
          const imports = 'import {extendAssetBundle, extendWorkspaceExport} from ' + JSON.stringify(moduleURL) + ';\\n';
          const updated = source.toString('utf8')
            .replace('export const getNetworkRequest = definePageTool(() => ({',
              'export const getNetworkRequest = definePageTool(() => extendWorkspaceExport(extendAssetBundle({')
            .replace('}));\\n//# sourceMappingURL=network.js.map', '}, zod), zod));\\n//# sourceMappingURL=network.js.map');
          return {...result, source: imports + updated};
        }
        if (url === snapshotTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              '48a72eacfcf1bb6eb3fbf97b2d33a0d9bc4528fd2c655557a80e0ff55e2df073') {
            throw new Error('Peekaboo: unaudited page wait tool');
          }
          const moduleURL = 'data:text/javascript,' + encodeURIComponent(pageWaitSource);
          const imports = 'import {extendPageWait} from ' + JSON.stringify(moduleURL) + ';\\n';
          const updated = source.toString('utf8')
            .replace('export const waitFor = definePageTool(() => ({',
              'export const waitFor = definePageTool(() => extendPageWait({')
            .replace('}));\\n//# sourceMappingURL=snapshot.js.map', '}, zod));\\n//# sourceMappingURL=snapshot.js.map');
          return {...result, source: imports + updated};
        }
        if (url === scriptTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'd5bfe13d873cc6ff1192cd27078e3d0c535bf1dae9aef21951b38f0e6025a386') {
            throw new Error('Peekaboo: unaudited script evaluation tool');
          }
          const updated = source.toString('utf8')
            .replace('waitForStableDom: zod',
              'skipNavigationWait: zod.boolean().optional()' +
              '.describe("Read-only scripts only; requires waitForStableDom=false"), waitForStableDom: zod')
            .replace('filePath, waitForStableDom, } = request.params;',
              'filePath, waitForStableDom, skipNavigationWait, } = request.params; ' +
              'if (skipNavigationWait && waitForStableDom !== false) ' +
              'throw new Error("skipNavigationWait requires waitForStableDom=false"); ' +
              'if (skipNavigationWait && serviceWorkerId) ' +
              'throw new Error("skipNavigationWait does not support service workers");')
            .replace("{ handleDialog: dialogAction ?? 'accept', waitForStableDom });",
              "{ handleDialog: dialogAction ?? 'accept', waitForStableDom, " +
              "expectNavigationIn: skipNavigationWait ? 0 : undefined });");
          return {...result, source: updated};
        }
        if (url === toolsTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              '337ab947e5c3c53bc90bf8eb76aa16931c94305196e506fe560f1859cc3dc10d') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP tool registry');
          }
          const moduleURL = 'data:text/javascript,' + encodeURIComponent(locatorSource);
          const imports = 'import {createLocatorTool} from ' + JSON.stringify(moduleURL) + ';\\n' +
            "import {zod as peekabooZod} from '../third_party/index.js';\\n" +
            "import {parseKey as peekabooParseKey} from '../utils/keyboard.js';\\n" +
            "import {definePageTool as peekabooDefinePageTool} from './ToolDefinition.js';\\n";
          const updated = source.toString('utf8').replace('const tools = [];',
            'const tools = [peekabooDefinePageTool(() => ' +
            'createLocatorTool({zod: peekabooZod, parseKey: peekabooParseKey}))(args)];');
          return {...result, source: imports + updated};
        }
        if (url === transportTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'c988e0684584b75e87ae04b768c4f8ae7064401afe5187ec0d4878b2c6833f12') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP dependencies');
          }
          const before = 'const ws = new WebSocket$1(url, [], {\\n                followRedirects: true,';
          const after = 'const ws = new WebSocket$1(url, [], {\\n' +
            '                followRedirects: false, handshakeTimeout: 60000,';
          return {...result, source: source.toString('utf8').replace(before, after)};
        }
        if (url === browserTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'e8ad9ae18a6836a0e56771afbf453b4b9ea1d384b4b0db9fccca04300a9fa222') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP browser transport');
          }
          const before = 'const connectOptions = {';
          const after = "if (this.#peekabooConnectionAttempted) throw new Error(" +
            "'Peekaboo: Chrome connection was already attempted; reconnect explicitly');\\n" +
            'this.#peekabooConnectionAttempted = true;\\n' +
            before;
          return {...result, source: source.toString('utf8')
            .replace('#browser;', '#browser;\\n    #peekabooConnectionAttempted = false;')
            .replace(before, after)};
        }
        if (url !== target) return result;
        const source = Buffer.from(result.source);
        if (createHash('sha256').update(source).digest('hex') !==
            'c2b1000dabc7c3bebba97561402e5496d0317a48c893e8eae0582a8293f948ff') {
          throw new Error('Peekaboo: unaudited Chrome DevTools MCP ToolHandler');
        }
        const before = 'devToolsData = await context.getDevToolsData(page);\\n' +
          '                pageUrl = context.getSelectedMcpPageUrl(page);';
        const after = 'if (ClearcutLogger.get()) {\\n' + before + '\\n            }';
        return {...result, source: source.toString('utf8').replace(before, after)};
      }
    `;
    register('data:text/javascript,' + encodeURIComponent(loader), {
      data: {target, browserTarget, transportTarget, toolsTarget, scriptTarget, snapshotTarget, networkTarget,
        locatorSource, pageWaitSource, assetBundleSource},
    });
    // Fail before starting the server (and before any browser connection) if the patch cannot load.
    await import(target);
    await import(browserTarget);
    const {McpServer} = await import(pathToFileURL(join(root, 'build/src/index.js')).href);
    const createServer = McpServer.from;
    McpServer.from = async function(args, options) {
      if (args.wsEndpoint && !options?.browserManager) {
        throw new Error('Peekaboo: provider browser owner missing');
      }
      const server = await createServer.call(this, args, options);
      if (args.wsEndpoint) {
        let connection;
        server.server.registerTool('peekaboo_browser_connect', {
          description: 'Verify the exact persistent browser connection for the Peekaboo owner.',
          inputSchema: {},
        }, async () => {
          // Cache failure too: no tool invocation may silently reopen Chrome's approval UI.
          connection ??= options.browserManager.ensureBrowser();
          try {
            const browser = await connection;
            if (!browser.connected) throw new Error('Chrome disconnected; reconnect explicitly');
            const session = await browser.target().createCDPSession();
            try {
              const version = await session.send('Browser.getVersion');
              return {content: [{type: 'text', text: JSON.stringify({
                webSocketDebuggerUrl: browser.wsEndpoint(), ...version,
              })}]};
            } finally {
              await session.detach();
            }
          } catch (error) {
            return {isError: true, content: [{type: 'text',
              text: 'Chrome connection failed: ' + String(error.cause?.message ?? error.message).slice(0, 512),
            }]};
          }
        });
      }
      return server;
    };
    process.argv = [process.execPath, entry, ...process.argv.slice(1)];
    await import(pathToFileURL(entry).href);
    """#.replacingOccurrences(
        of: "__PEEKABOO_LOCATOR_SOURCE__",
        with: Data((BrowserMCPInputTransfers.source + "\n" + BrowserMCPLocatorResolver.source).utf8)
            .base64EncodedString())
        .replacingOccurrences(
            of: "__PEEKABOO_PAGE_WAIT_SOURCE__",
            with: Data(BrowserMCPPageWait.source.utf8).base64EncodedString())
        .replacingOccurrences(
            of: "__PEEKABOO_ASSET_BUNDLE_SOURCE__",
            with: Data((BrowserMCPWorkspaceExport.source + "\n" + BrowserMCPAssetBundle.source).utf8)
                .base64EncodedString())
}
