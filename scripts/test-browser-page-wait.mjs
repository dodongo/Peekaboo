import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {zod} from '../node_modules/chrome-devtools-mcp/build/src/third_party/index.js';
const swift=readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPPageWait.swift',import.meta.url),'utf8');
const source=swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1];
const {extendPageWait}=await import('data:text/javascript,'+encodeURIComponent(source));
function fixture(){
 const calls=[],lines=[];
 const tool=extendPageWait({schema:{text:zod.array(zod.string()).min(1)},handler:async request=>calls.push(['text',request.params.text])},zod);
 const page={url:()=> 'https://example.com/ready',
  waitForFunction:async(fn,options,params)=>{assert.ok(options.timeout>0&&options.timeout<=1000);calls.push(['wait',params]);return{dispose:async()=>calls.push(['dispose'])};},
  waitForNetworkIdle:async options=>{assert.equal(options.idleTime,500);assert.equal(options.concurrency,0);calls.push(['idle']);},
  evaluate:async()=>true};
 return {tool,page,calls,lines,run:params=>tool.handler({params,page:{pptrPage:page}},{appendResponseLine:line=>lines.push(line)})};
}
test('existing text waits retain the original handler',async()=>{const f=fixture();await f.run({text:['Ready']});assert.deepEqual(f.calls,[['text',['Ready']]]);assert.deepEqual(f.lines,[]);});
test('URL/load waits dispose the handle and return a compact receipt',async()=>{
 const f=fixture();await f.run({url:{regex:'ready$',flags:'i'},loadState:'load',timeout:1000});
 assert.deepEqual(f.calls.map(x=>x[0]),['wait','dispose']);
 assert.deepEqual(JSON.parse(f.lines[0]),{state:'satisfied',url:'https://example.com/ready',loadState:'load'});
});
test('network quiet rechecks the matching document and repeats after a navigation',async()=>{
 const f=fixture();let checks=0;f.page.evaluate=async()=>++checks>1;
 await f.run({loadState:'networkidle',timeout:1000});
 assert.deepEqual(f.calls.map(x=>x[0]),['wait','dispose','idle','wait','dispose','idle']);
});
test('malformed or mixed conditions fail before a page wait starts',async()=>{
 const f=fixture();for(const params of [{},{text:['x'],url:'x'},{url:'x',timeout:0},{url:'x',timeout:20001}])await assert.rejects(f.run(params));
 assert.deepEqual(f.calls,[]);
 const schema=zod.object(f.tool.schema);
 for(const params of [{url:{regex:'['}},{url:{regex:'x',flags:'ii'}},{loadState:'unknown'},{url:''}])assert.equal(schema.safeParse(params).success,false);
});
test('URL matching and load-state predicates use the current document',async()=>{
 const f=fixture();let predicate;
 f.page.waitForFunction=async fn=>{predicate=fn;return{dispose:async()=>{}};};
 await f.run({url:'https://example.com/ready',timeout:1000});
 const oldLocation=globalThis.location,oldDocument=globalThis.document;
 try{
  globalThis.location={href:'https://example.com/ready'};globalThis.document={readyState:'interactive'};
  assert.equal(predicate({url:'https://example.com/ready',loadState:'domcontentloaded'}),true);
  assert.equal(predicate({url:'https://example.com/ready',loadState:'load'}),false);
  assert.equal(predicate({url:{regex:'READY$',flags:'ig'}}),true);
  assert.equal(predicate({url:{regex:'READY$',flags:'ig'}}),true);
  assert.equal(predicate({url:'https://example.com/other'}),false);
  globalThis.document.readyState='complete';assert.equal(predicate({loadState:'networkidle'}),true);
 }finally{if(oldLocation===undefined)delete globalThis.location;else globalThis.location=oldLocation;if(oldDocument===undefined)delete globalThis.document;else globalThis.document=oldDocument;}
});
