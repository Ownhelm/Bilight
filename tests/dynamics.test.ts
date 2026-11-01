import test from 'node:test';
import assert from 'node:assert/strict';
import { DynamicLikes } from '../src/dynamicLikes.js';
import type { VideoDynamic } from '../shared/types.js';
function deferred<T>() { let resolve!: (v:T)=>void, reject!: (e:Error)=>void; const promise=new Promise<T>((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject}; }
const id='1057955152016703512', initial={liked:false,likes:12};
test('feed and detail share pending and confirmed state, duplicate taps coalesce and old reads cannot overwrite it', async()=>{
 const gate=deferred<VideoDynamic>();let writes=0;
 const store=new DynamicLikes(async(key,target)=>{assert.equal(key,id);assert.equal(target,true);writes++;return gate.promise;});
 store.ingest(id,initial,store.readVersion());const readVersion=store.readVersion();
 const first=store.toggle(id,initial), second=store.toggle(id,initial); assert.equal(first,second);
 assert.deepEqual(store.getSnapshot().states[id],initial);assert.equal(store.getSnapshot().pending[id],true);
 gate.resolve({liked:true,likes:21} as VideoDynamic);await first;
 assert.equal(writes,1);assert.deepEqual(store.getSnapshot().states[id],{liked:true,likes:21});assert.deepEqual(store.getSnapshot().pending,{});
 store.ingest(id,initial,readVersion);assert.equal(store.getSnapshot().states[id].liked,true);
 store.ingest(id,{liked:false,likes:30},store.readVersion());assert.equal(store.getSnapshot().states[id].likes,30);
});
test('failed requests restore state and account clearing discards late confirmations',async()=>{
 const failed=new DynamicLikes(async()=>{throw new Error('Risk control');});
 await assert.rejects(failed.toggle(id,initial),/Risk control/);assert.deepEqual(failed.getSnapshot().states[id],initial);assert.deepEqual(failed.getSnapshot().pending,{});
 const gate=deferred<VideoDynamic>();let signal:AbortSignal|undefined;
 const store=new DynamicLikes(async(_id,_target,s)=>{signal=s;return gate.promise;});
 const pending=store.toggle(id,initial);await Promise.resolve();store.clear();assert.equal(signal?.aborted,true);
 gate.resolve({liked:true,likes:99} as VideoDynamic);await pending;assert.deepEqual(store.getSnapshot(),{states:{},pending:{}});
});
