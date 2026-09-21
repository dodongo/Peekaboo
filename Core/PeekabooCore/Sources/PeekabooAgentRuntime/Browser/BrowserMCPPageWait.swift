/// Page waits extend the existing provider tool without adding another public operation.
enum BrowserMCPPageWait {
    static let source = #"""
    export function extendPageWait(tool, zod) {
      const regex = zod.object({regex: zod.string().max(8192), flags: zod.string().max(8).optional()})
        .strict().refine(value => {
          try { new RegExp(value.regex, value.flags ?? ''); return true; }
          catch { return false; }
        }, 'Invalid JavaScript URL regular expression');
      return {
        ...tool,
        description: 'Wait for text, a URL, or a page load state. URL/page waits return a compact receipt.',
        schema: {
          ...tool.schema,
          text: tool.schema.text.optional(),
          url: zod.union([zod.string().min(1).max(8192), regex]).optional(),
          loadState: zod.enum(['domcontentloaded', 'load', 'networkidle']).optional(),
        },
        handler: async (request, response) => {
          const params = request.params;
          const pageWait = params.url !== undefined || params.loadState !== undefined;
          if (!pageWait) {
            if (!params.text) throw new Error('Wait requires text, url or loadState');
            return tool.handler(request, response);
          }
          if (params.text !== undefined) throw new Error('Text waits cannot be mixed with URL/load-state waits');
          const timeout = params.timeout ?? 5000;
          if (!Number.isInteger(timeout) || timeout < 1 || timeout > 20000) {
            throw new Error('Page wait timeout must be an integer in 1..20000 milliseconds');
          }
          const deadline = performance.now() + timeout;
          const remaining = () => {
            const value = Math.ceil(deadline - performance.now());
            if (value <= 0) throw new Error('Page wait timed out');
            return value;
          };
          const matches = config => {
            const url = location.href;
            if (typeof config.url === 'string' && url !== config.url) return false;
            if (config.url && typeof config.url === 'object' &&
                !new RegExp(config.url.regex, config.url.flags ?? '').test(url)) return false;
            if (config.loadState === 'domcontentloaded' && document.readyState === 'loading') return false;
            if (['load', 'networkidle'].includes(config.loadState) && document.readyState !== 'complete') return false;
            return true;
          };
          const page = request.page.pptrPage;
          while (true) {
            const handle = await page.waitForFunction(matches, {polling: 100, timeout: remaining()}, params);
            await handle.dispose();
            if (params.loadState !== 'networkidle') break;
            await page.waitForNetworkIdle({idleTime: 500, concurrency: 0, timeout: remaining()});
            // Navigation may have happened while waiting for quiet. Recheck the current document.
            try {
              if (await page.evaluate(matches, params)) break;
            } catch (error) {
              if (!/Execution context was destroyed|Cannot find context with specified id/.test(error.message)) {
                throw error;
              }
            }
          }
          const url = page.url();
          if (url.length > 8192) throw new Error('Page URL exceeds the 8192-character receipt limit');
          response.appendResponseLine(JSON.stringify({state: 'satisfied', url,
            ...(params.loadState ? {loadState: params.loadState} : {})}));
        },
      };
    }
    """#
}
