import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTools } from '../dist/tools.js';
import { resolveConfig, runTask, sync } from '../src/task.mjs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
if (process.env.TASK_DRAIN_INTEGRATION !== '1' || !process.env.TASKRC || !process.env.TASK_BIN) throw new Error('Explicit scratch TASKRC, TASK_BIN and TASK_DRAIN_INTEGRATION=1 required');
const config=resolveConfig();const tools=createTools(config);
const call=async(name,input={})=>JSON.parse((await tools.find(t=>t.name===name).execute(input,{})).content);
test('real shared handlers complete full review lifecycle and dependencies',async()=>{
 const ids=[];
 try {
  const a=await call('add',{description:'Handler integration primary',project:'drain-scratch',actor:'test',tags:['noauto']});ids.push(a.uuid);
  await call('claim',{uuid:a.uuid,actor:'test'});
  await call('start',{uuid:a.uuid,actor:'test'});
  await call('submit_for_review',{uuid:a.uuid,actor:'test',evidence:'Observed integration test execution'});
  await assert.rejects(()=>call('complete',{uuid:a.uuid,actor:'test'}),/requires \+approved/);
  await call('approve',{uuid:a.uuid,actor:'test'});
  assert.equal((await call('complete',{uuid:a.uuid,actor:'test'})).status,'completed');
  const b=await call('add',{description:'Dependency blocker',tags:['noauto']});ids.push(b.uuid);
  const c=await call('add',{description:'Dependency dependent',tags:['noauto']});ids.push(c.uuid);
  await call('add_dependency',{uuid:c.uuid,depends_on:b.uuid});
  assert.ok((await call('blocked_tasks')).tasks.some(t=>t.uuid===c.uuid));
 } finally {for(const id of ids) await runTask(config,['rc.confirmation=off',id,'delete']);await sync(config);}
});
test('MCP stdio lists tools, mutates and reads a scratch task',async()=>{
 const client=new Client({name:'drain-integration',version:'1.0.0'});
 const transport=new StdioClientTransport({command:process.execPath,args:['dist/mcp-server.js'],env:process.env});
 let id;
 try {
  await client.connect(transport);
  assert.equal((await client.listTools()).tools.length,22);
  const added=await client.callTool({name:'task_add',arguments:{description:'MCP integration task',tags:['noauto']}});
  id=JSON.parse(added.content[0].text).uuid;assert.ok(id);
  const got=await client.callTool({name:'task_get',arguments:{uuid:id}});
  assert.equal(JSON.parse(got.content[0].text).task.uuid,id);
 } finally {await client.close();if(id){await runTask(config,['rc.confirmation=off',id,'delete']);await sync(config);}}
});
