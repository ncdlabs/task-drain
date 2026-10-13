import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, symlink, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createTools } from '../dist/tools.js';
import { createFakeTask } from './helpers/fake-task.mjs';
const uuid='11111111-1111-4111-8111-111111111111';
async function fixture(fn) { const fake=createFakeTask(); try { await fn(fake, name=>createTools(fake.config).find(t=>t.name===name)); } finally {fake.cleanup();} }
test('review alone cannot complete and force requires a reason',()=>fixture(async(f,t)=>{
 f.setResponses([{match:'export',stdout:JSON.stringify({uuid,status:'pending',tags:['ready-for-review']})+'\n'}]);
 await assert.rejects(()=>t('complete').execute({uuid,actor:'a'},{}),/requires \+approved/);
 await assert.rejects(()=>t('complete').execute({uuid,actor:'a',force:true},{}),/requires a note/);
 assert.equal(f.getCalls().filter(c=>c.includes('done')).length,0);
}));
test('claim rejects worker-owned tasks even with force',()=>fixture(async(f,t)=>{
 f.setResponses([{match:'export',stdout:JSON.stringify({uuid,status:'pending',tags:['drain-claimed']})+'\n'}]);
 await assert.rejects(()=>t('claim').execute({uuid,actor:'a',force:true},{}),/in review/);
}));
test('auto ignores noauto, future scheduled and review tasks',()=>fixture(async(f,t)=>{
 f.setResponses([{match:'export',stdout:[{uuid,status:'pending',tags:['noauto']},{uuid,status:'pending',scheduled:'29990101T000000Z'},{uuid,status:'pending',tags:['ready-for-review']}].map(JSON.stringify).join('\n')}]);
 assert.equal(JSON.parse((await t('auto').execute({actor:'a',project:'target'},{})).content).action,'none_found');
 assert.ok(f.getCalls().some(c=>c.includes('project:target')&&c.includes('-BLOCKED')));
}));
test('blocked query uses dependency-aware virtual filter',()=>fixture(async(f,t)=>{
 f.setResponses([{match:'export',stdout:JSON.stringify({uuid,status:'pending',depends:['22222222-2222-4222-8222-222222222222']})+'\n'}]);
 assert.equal(JSON.parse((await t('blocked_tasks').execute({},{})).content).count,1);
 assert.ok(f.getCalls().some(c=>c.includes('(+BLOCKED or +blocked)')));
}));
test('setup refuses overwrite and symlink escape', async()=>{
 const root=await mkdtemp(join(tmpdir(),'drain-setup-'));const outside=await mkdtemp(join(tmpdir(),'drain-outside-'));const prev=process.cwd();process.chdir(root);
 try {
  const t=createTools({bin:'unused',autoSync:false}).find(t=>t.name==='setup');
  await t.execute({write:true},{});
  await assert.rejects(()=>t.execute({write:true},{}),/EEXIST/);
  await t.execute({write:true,overwrite:true},{});
  await symlink(outside,join(root,'escape'));
  await assert.rejects(()=>t.execute({write:true,outputPath:'escape/install.sh'},{}),/escapes/);
 } finally {process.chdir(prev);await rm(root,{recursive:true,force:true});await rm(outside,{recursive:true,force:true});}
});
