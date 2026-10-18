import {readFileSync} from 'node:fs';

const root = new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/', import.meta.url);
const extract = name => readFileSync(new URL(name, root), 'utf8')
  .match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1].replace(/^    /gm, '');

export function locatorSource() {
  return extract('BrowserMCPInputTransfers.swift') + '\n' + extract('BrowserMCPLocatorResolver.swift');
}

// Expand the same embedded source composition used by the compiled Swift host.
export function providerBootstrapSource() {
  return extract('BrowserMCPProviderBootstrap.swift').replace('__PEEKABOO_LOCATOR_SOURCE__',
    Buffer.from(locatorSource()).toString('base64'))
    .replace('__PEEKABOO_PAGE_WAIT_SOURCE__', Buffer.from(extract('BrowserMCPPageWait.swift')).toString('base64'))
    .replace('__PEEKABOO_ASSET_BUNDLE_SOURCE__', Buffer.from(extract('BrowserMCPWorkspaceExport.swift') + '\n' + extract('BrowserMCPAssetBundle.swift')).toString('base64'));
}
