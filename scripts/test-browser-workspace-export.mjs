import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {zod} from '../node_modules/chrome-devtools-mcp/build/src/third_party/index.js';
const swift=readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPWorkspaceExport.swift',import.meta.url),'utf8');
const {workspaceExportURL,extendWorkspaceExport}=await import('data:text/javascript,'+encodeURIComponent(swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1]));
const source='https://docs.google.com/spreadsheets/d/fixture_id/edit#gid=42';
test('export URLs derive only from supported observed Workspace documents',()=>{
 assert.equal(workspaceExportURL(source,'csv'),'https://docs.google.com/spreadsheets/d/fixture_id/export?format=csv&gid=42');
 assert.equal(workspaceExportURL(source,'xlsx'),'https://docs.google.com/spreadsheets/d/fixture_id/export?format=xlsx');
 assert.equal(workspaceExportURL('https://docs.google.com/document/u/2/d/abc/edit','docx'),'https://docs.google.com/document/d/abc/export?format=docx&authuser=2');
 assert.equal(workspaceExportURL('https://docs.google.com/presentation/d/abc/edit','pptx'),'https://docs.google.com/presentation/d/abc/export/pptx');
 for(const url of ['http://docs.google.com/spreadsheets/d/abc/edit','https://docs.google.com.evil.test/spreadsheets/d/abc/edit','https://user@docs.google.com/spreadsheets/d/abc/edit','https://docs.google.com:123/spreadsheets/d/abc/edit','https://docs.google.com/not-a-document'])assert.throws(()=>workspaceExportURL(url,'csv'));
 assert.throws(()=>workspaceExportURL(source,'docx'),/Unsupported/);
});
function fixture({data=Buffer.from('header\nvalue'),status=200,mime='text/csv',change=false}={}){
 const commands=[],saved=[],lines=[];let url=source,detached=false;
 const client={send:async(method,args,options)=>{commands.push([method,args]);assert.ok(options.timeout>0);
  if(method==='Network.loadNetworkResource')return {resource:{success:status===200,httpStatusCode:status,stream:'fixture',headers:{'Content-Type':mime}}};
  if(method==='IO.read'){if(change)url+='changed';return{data:data.toString('base64'),base64Encoded:true,eof:true};}
  if(method==='IO.close')return{};
  throw new Error('Unexpected command');},detach:async()=>{detached=true;}};
 const tool=extendWorkspaceExport({schema:{},handler:async()=>{lines.push('legacy');}},zod);
 const run=params=>tool.handler({params,page:{pptrPage:{url:()=>url,mainFrame:()=>({_id:'frame'}),createCDPSession:async()=>client}}},
  {appendResponseLine:line=>lines.push(JSON.parse(line))},{saveFile:async(data,path)=>{saved.push(data);return{filename:path};}});
 return{run,commands,saved,lines,detached:()=>detached};
}
test('document exports use browser credentials, retain bytes and close IO/session',async()=>{
 const f=fixture();await f.run({documentFormat:'csv',responseFilePath:'/private/test.csv'});
 assert.deepEqual(f.commands.map(c=>c[0]),['Network.loadNetworkResource','IO.read','IO.close']);
 assert.deepEqual(f.commands[0][1].options,{disableCache:false,includeCredentials:true});
 assert.equal(f.saved[0].toString(),'header\nvalue');assert.equal(f.lines[0].export.bytes,12);assert.equal(f.lines[0].export.sha256.length,64);assert.equal(f.detached(),true);
});
test('failure, navigation change, HTML and oversized responses leave no artifact',async()=>{
 for(const options of [{status:403},{mime:'text/html'},{change:true},{data:Buffer.alloc(33554433)}]){
  const f=fixture(options);await assert.rejects(f.run({documentFormat:'csv',responseFilePath:'/private/test.csv'}));
  assert.equal(f.saved.length,0);assert.equal(f.commands.at(-1)[0],'IO.close');assert.equal(f.detached(),true);
 }
 const f=fixture();await assert.rejects(f.run({documentFormat:'pdf',responseFilePath:'/private/test.pdf'}),/file format/);assert.equal(f.saved.length,0);
});
test('mixed options and stale identity fail before network; existing tool behavior stays available',async()=>{
 const f=fixture();
 for(const params of [{documentFormat:'csv'},{documentFormat:'csv',responseFilePath:'/private/a',reqid:1},{documentFormat:'csv',responseFilePath:'/private/a',expectedURL:'changed'}])await assert.rejects(f.run(params));
 assert.equal(f.commands.length,0);await f.run({reqid:1});assert.equal(f.lines[0],'legacy');
});
