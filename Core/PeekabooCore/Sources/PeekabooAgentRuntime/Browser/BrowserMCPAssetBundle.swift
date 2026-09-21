/// Batch captured responses through the existing network tool; no page fetch or catalog expansion.
enum BrowserMCPAssetBundle {
    static let source = #"""
    export function extendAssetBundle(tool, zod) {
      return {
        ...tool,
        schema: {
          ...tool.schema,
          assets: zod.array(zod.object({id: zod.string().min(1).max(128),
            url: zod.string().min(1).max(8192)}).strict()).min(1).max(16).optional(),
          expectedURL: zod.string().min(1).max(8192).optional(),
          maxAssetBytes: zod.number().int().min(1).max(268435456).optional(),
        },
        handler: async (request, response, context) => {
          const {assets, expectedURL, responseFilePath, requestFilePath, reqid, maxAssetBytes} = request.params;
          if (!assets) {
            if (expectedURL !== undefined || maxAssetBytes !== undefined) {
              throw new Error('Bundle options require assets');
            }
            return tool.handler(request, response, context);
          }
          if (!responseFilePath || !expectedURL || requestFilePath !== undefined || reqid !== undefined) {
            throw new Error('Asset bundle requires expectedURL and responseFilePath without reqid/requestFilePath');
          }
          if (new Set(assets.map(asset => asset.id)).size !== assets.length) throw new Error('Duplicate asset IDs');
          if (request.page.pptrPage.url() !== expectedURL) throw new Error('Page changed since inventory');
          const normalize = value => { const url = new URL(value); url.hash = ''; return url.href; };
          // Current navigation only; never substitute a response from a previous document.
          const captured = request.page.getNetworkRequests(false);
          const byURL = new Map();
          for (const item of captured) {
            if (item.method() === 'GET') byURL.set(normalize(item.url()), item);
          }
          const limit = maxAssetBytes ?? 67108864;
          const results = new Array(assets.length);
          let next = 0, totalBytes = 0;
          const worker = async () => {
            while (next < assets.length) {
              const index = next++, asset = assets[index];
              try {
                const item = byURL.get(normalize(asset.url));
                if (!item) throw new Error('No captured response for this asset');
                const reply = item.response();
                if (!reply) throw new Error('Response is not available');
                if (reply.status() < 200 || reply.status() >= 300) throw new Error('HTTP ' + reply.status());
                let timer;
                let data;
                try {
                  data = await Promise.race([reply.buffer(), new Promise((_, reject) => {
                    timer = setTimeout(() => reject(new Error('Captured response read timed out')), 10000);
                  })]);
                } finally { clearTimeout(timer); }
                if (data.byteLength > limit || totalBytes + data.byteLength > 268435456) {
                  throw new Error('Captured asset exceeds bundle byte limit');
                }
                totalBytes += data.byteLength;
                if (request.page.pptrPage.url() !== expectedURL) throw new Error('Page changed during bundle');
                const saved = await context.saveFile(
                  data, responseFilePath + '-' + index + '.network-response', '.network-response');
                results[index] = {id: asset.id, path: saved.filename, bytes: data.byteLength,
                  contentType: reply.headers()['content-type'] ?? null, source: 'captured-response'};
              } catch (error) {
                results[index] = {id: asset.id, error: String(error.message ?? error).slice(0, 256)};
              }
            }
          };
          await Promise.all(Array.from({length: Math.min(4, assets.length)}, worker));
          response.appendResponseLine(JSON.stringify({results}));
        },
      };
    }
    """#
}
