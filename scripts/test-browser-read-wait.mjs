import assert from 'node:assert/strict';
import {test} from 'node:test';
import {delimiter} from 'node:path';
import {fileURLToPath} from 'node:url';
import {providerBootstrapSource} from './browser-provider-source.mjs';
const oldPath=process.env.PATH;
process.env.PATH=fileURLToPath(new URL('../node_modules/.bin',import.meta.url))+delimiter+oldPath;
await import('data:text/javascript,'+encodeURIComponent(providerBootstrapSource().split('process.argv =')[0]));
process.env.PATH=oldPath;
const {evaluateScript}=await import('../node_modules/chrome-devtools-mcp/build/src/tools/script.js');
const {zod}=await import('../node_modules/chrome-devtools-mcp/build/src/third_party/index.js');

test('evaluateScript preserves the default navigation probe and allows explicit read-only opt-out',async()=>{
 for(const skip of [undefined,false,true]){
  const tool=evaluateScript({pageIdRouting:true});
  let options,disposed=false;
  const page={pptrPage:{
   async evaluateHandle(){return {[Symbol.dispose](){disposed=true}}},
   async evaluate(){return JSON.stringify({count:3})},
  },async waitForEventsAfterAction(action, supplied){options=supplied;await action();return {dialogHandled:false}}};
  const lines=[];
  const params={pageId:7,function:'()=>({count:3})',waitForStableDom:false};
  if(skip!==undefined)params.skipNavigationWait=skip;
  assert.equal(zod.object(tool.schema).safeParse(params).success,true);
  await tool.handler({params},{appendResponseLine(line){lines.push(line)},attachWaitForResult(){}},{getPageById(id){assert.equal(id,7);return page}});
  assert.equal(options.expectNavigationIn,skip?0:undefined);
  assert.ok(disposed);
  assert.ok(lines.includes('{"count":3}'));
 }
});

test('evaluateScript rejects conflicting wait settings and workers before evaluation',async()=>{
 const tool=evaluateScript({pageIdRouting:true});
 for(const extra of [{},{waitForStableDom:true},{waitForStableDom:false,serviceWorkerId:'worker'}]){
  await assert.rejects(tool.handler({params:{pageId:7,function:'()=>1',skipNavigationWait:true,...extra}},{},{}),/skipNavigationWait/);
 }
 assert.equal(zod.object(tool.schema).safeParse({pageId:7,function:'()=>1',skipNavigationWait:'yes'}).success,false);
});
