import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {zod} from '../node_modules/chrome-devtools-mcp/build/src/third_party/index.js';
const swift=readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPAssetBundle.swift',import.meta.url),'utf8');
const {extendAssetBundle}=await import('data:text/javascript,'+encodeURIComponent(swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1]));
function fixture(){
 const saved=[],lines=[],legacy=[];let url='https://example.com/';
 const request=(url,data,status=200)=>({url:()=>url,method:()=> 'GET',response:()=>({status:()=>status,buffer:async()=>data,headers:()=>({'content-type':'image/png'})})});
 const requests=[request('https://cdn.example.com/a.png',Buffer.from([0,255,128])),request('https://example.com/empty',Buffer.alloc(0)),request('https://example.com/bad',Buffer.from('no'),404)];
 const tool=extendAssetBundle({schema:{},handler:async(...args)=>legacy.push(args)},zod);
 const run=params=>tool.handler({params,page:{pptrPage:{url:()=>url},getNetworkRequests:preserved=>{assert.equal(preserved,false);return requests;}}},
  {appendResponseLine:line=>lines.push(JSON.parse(line))},{saveFile:async(data,path,extension)=>{saved.push({data,path});return{filename:path.replace(/\.[^/.]+$/,'')+extension};}});
 return{tool,run,saved,lines,legacy,setURL:value=>url=value};
}
const base={expectedURL:'https://example.com/',responseFilePath:'/private/artifact'};
test('captured cross-origin and empty bodies save original bytes without fetching',async()=>{
 const f=fixture();await f.run({...base,assets:[{id:'a1',url:'https://cdn.example.com/a.png#fragment'},{id:'a2',url:'https://example.com/empty'}]});
 assert.deepEqual([...f.saved[0].data],[0,255,128]);assert.equal(f.saved[1].data.length,0);
 assert.equal(f.lines[0].results[0].source,'captured-response');
 assert.notEqual(f.lines[0].results[0].path,f.lines[0].results[1].path);
});
test('missing, failed and oversized assets retain independent success',async()=>{
 const f=fixture();await f.run({...base,maxAssetBytes:1,assets:[{id:'a',url:'https://cdn.example.com/a.png'},{id:'b',url:'https://example.com/empty'},{id:'c',url:'https://example.com/bad'},{id:'d',url:'https://example.com/missing'}]});
 assert.equal(f.saved.length,1);assert.equal(f.lines[0].results.filter(x=>x.error).length,3);
});
test('stale page and invalid mixed options fail before saving',async()=>{
 const f=fixture(),assets=[{id:'a',url:'https://cdn.example.com/a.png'}];
 for(const params of [{...base,assets,reqid:1},{...base,assets,requestFilePath:'/x'},{assets},{...base,assets:[...assets,...assets]}])await assert.rejects(f.run(params));
 f.setURL('https://example.com/changed');await assert.rejects(f.run({...base,assets}),/Page changed/);assert.equal(f.saved.length,0);
});
test('ordinary network requests still use the original handler',async()=>{
 const f=fixture();await f.run({reqid:1});assert.equal(f.legacy.length,1);assert.equal(f.saved.length,0);
});
test('bundle schema bounds selection and byte limits',()=>{
 const f=fixture(),schema=zod.object(f.tool.schema);
 for(const value of [{assets:[]},{assets:Array(17).fill({id:'a',url:'https://e.com/'})},{maxAssetBytes:0},{maxAssetBytes:268435457}])assert.equal(schema.safeParse(value).success,false);
});
