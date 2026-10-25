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
test('claim rejects drain-claimed takeover with force alone, allows explicit override',()=>fixture(async(f,t)=>{
  f.setResponses([{match:'export',stdout:JSON.stringify({uuid,status:'pending',tags:['drain-claimed']})+'\n'}]);
  await assert.rejects(()=>t('claim').execute({uuid,actor:'a',force:true},{}),/overrideDrainClaim/);
  const taskData=JSON.stringify({uuid,status:'pending',tags:['drain-claimed']})+'\n';
  f.setResponses([
    {match:'export',stdout:taskData},
    {match:'modify',stdout:'Modified.\n'},
    {match:'annotate',stdout:'Annotation added.\n'},
    {match:'annotate',stdout:'Annotation added.\n'},
    {match:'export',stdout:taskData},
  ]);
  const r=await t('claim').execute({uuid,actor:'a',force:true,overrideDrainClaim:true,overrideReason:'admin recovery: worker host retired'},{});
  assert.ok(r.content.includes(uuid));
  assert.ok(f.getCalls().some(c=>JSON.stringify(c).includes('drain-override')));
}));
test('claim override without a reason is rejected',()=>fixture(async(f,t)=>{
  f.setResponses([{match:'export',stdout:JSON.stringify({uuid,status:'pending',tags:['drain-claimed']})+'\n'}]);
  await assert.rejects(()=>t('claim').execute({uuid,actor:'a',force:true,overrideDrainClaim:true},{}),/overrideReason/);
  await assert.rejects(()=>t('claim').execute({uuid,actor:'a',overrideDrainClaim:true,overrideReason:'  '},{}),/overrideReason/);
}));
test('claim allows same-actor reclaim without force',()=>fixture(async(f,t)=>{
  const taskData=JSON.stringify({uuid,status:'pending',tags:['claimed'],annotations:[{description:'claimed by a'}]})+'\n';
  f.setResponses([
    {match:'export',stdout:taskData},
    {match:'modify',stdout:'Modified.\n'},
    {match:'annotate',stdout:'Annotation added.\n'},
    {match:'export',stdout:taskData},
  ]);
  const r=await t('claim').execute({uuid,actor:'a'},{});
  assert.ok(r.content.includes(uuid));
}));
test('claim allows in-review tasks with force',()=>fixture(async(f,t)=>{
  const taskData=JSON.stringify({uuid,status:'pending',tags:['ready-for-review']})+'\n';
  f.setResponses([
    {match:'export',stdout:taskData},
    {match:'modify',stdout:'Modified.\n'},
    {match:'annotate',stdout:'Annotation added.\n'},
    {match:'export',stdout:taskData},
  ]);
  const r=await t('claim').execute({uuid,actor:'a',force:true},{});
  assert.ok(r.content.includes(uuid));
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
