/// Export the selected Workspace document through Chrome's network session without exposing cookies.
enum BrowserMCPWorkspaceExport {
    static let source = #"""
    import {createHash} from 'node:crypto';
    export function workspaceExportURL(source, format) {
      const url = new URL(source);
      const match = /^\/(document|spreadsheets|presentation)\/(?:u\/(\d+)\/)?d\/([A-Za-z0-9_-]{1,256})(?:\/|$)/
        .exec(url.pathname);
      if (url.protocol !== 'https:' || url.hostname !== 'docs.google.com' || url.port ||
          url.username || url.password || !match) throw new Error('Selected page is not a Workspace document');
      const [, kind, account, id] = match;
      const formats = {document: ['pdf', 'docx', 'md'], spreadsheets: ['pdf', 'xlsx', 'csv'],
        presentation: ['pdf', 'pptx']};
      if (!formats[kind].includes(format)) throw new Error('Unsupported export format for selected document');
      const result = new URL('https://docs.google.com/' + kind + '/d/' + id + '/export');
      if (kind === 'presentation') result.pathname += '/' + format;
      else result.searchParams.set('format', format);
      const authuser = account ?? url.searchParams.get('authuser');
      if (authuser && /^\d+$/.test(authuser)) result.searchParams.set('authuser', authuser);
      if (kind === 'spreadsheets' && format === 'csv') {
        const gid = new URLSearchParams(url.hash.slice(1)).get('gid') ?? url.searchParams.get('gid');
        if (gid && /^\d+$/.test(gid)) result.searchParams.set('gid', gid);
      }
      return result.href;
    }
    export function extendWorkspaceExport(tool, zod) {
      return {
        ...tool,
        schema: {...tool.schema, documentFormat: zod.enum(['pdf', 'md', 'xlsx', 'csv', 'docx', 'pptx']).optional()},
        handler: async (request, response, context) => {
          const params = request.params;
          if (params.documentFormat === undefined) return tool.handler(request, response, context);
          if (!params.responseFilePath || Object.keys(params).some(key =>
              !['documentFormat', 'responseFilePath', 'expectedURL', 'pageId'].includes(key))) {
            throw new Error('Document export requires responseFilePath without other network options');
          }
          const page = request.page.pptrPage, sourceURL = page.url(), format = params.documentFormat;
          if (sourceURL.length > 8192 || (params.expectedURL && sourceURL !== params.expectedURL)) {
            throw new Error('Selected document changed before export');
          }
          const url = workspaceExportURL(sourceURL, format);
          const deadline = performance.now() + 20000;
          const client = await page.createCDPSession();
          let stream;
          const send = (method, args) => {
            const timeout = Math.ceil(deadline - performance.now());
            if (timeout < 1) throw new Error('Document export timed out');
            return client.send(method, args, {timeout});
          };
          try {
            const {resource} = await send('Network.loadNetworkResource', {
              frameId: page.mainFrame()._id, url, options: {disableCache: false, includeCredentials: true},
            });
            stream = resource.stream;
            if (!resource.success || resource.httpStatusCode !== 200 || !stream) {
              throw new Error('Document export failed: HTTP ' + resource.httpStatusCode);
            }
            const contentType = Object.entries(resource.headers ?? [])
              .find(([key]) => key.toLowerCase() === 'content-type')?.[1] ?? '';
            if (/text\/html/i.test(contentType)) throw new Error('Document export returned an HTML page');
            const chunks = []; let bytes = 0;
            while (true) {
              const chunk = await send('IO.read', {handle: stream, size: 65536});
              const data = Buffer.from(chunk.data, chunk.base64Encoded ? 'base64' : 'utf8');
              bytes += data.length;
              if (bytes > 33554432) throw new Error('Document export exceeds 32 MiB');
              chunks.push(data);
              if (chunk.eof) break;
            }
            const data = Buffer.concat(chunks);
            if ((format === 'pdf' && data.subarray(0, 5).toString() !== '%PDF-') ||
                (['docx', 'xlsx', 'pptx'].includes(format) &&
                 !data.subarray(0, 4).equals(Buffer.from([80, 75, 3, 4])))) {
              throw new Error('Document export returned an unexpected file format');
            }
            if (page.url() !== sourceURL) throw new Error('Selected document changed during export');
            const saved = await context.saveFile(data, params.responseFilePath, '.' + format);
            response.appendResponseLine(JSON.stringify({export: {path: saved.filename, format, bytes, sourceURL,
              contentType, sha256: createHash('sha256').update(data).digest('hex')}}));
          } finally {
            if (stream) await client.send('IO.close', {handle: stream}, {timeout: 1000}).catch(() => {});
            await client.detach().catch(() => {});
          }
        },
      };
    }
    """#
}
