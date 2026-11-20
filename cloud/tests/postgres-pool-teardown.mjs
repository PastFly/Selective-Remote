import pg from 'pg';
import assert from 'node:assert/strict';
import {once} from 'node:events';

// pg-pool can report end after removing clients from its list, before their
// sockets emit end. Never terminate those still-closing sessions with DROP FORCE.
// Public pool/client events let fixtures await closure without private fields,
// polling, retry loops, time delays or swallowing genuine pool errors.
export function trackTestPoolClosure(pool){
 const closingClients=new Set(),end=pool.end.bind(pool);
 pool.on('connect',client=>{
  let resolve;const closed=new Promise(done=>{resolve=done;});closingClients.add(closed);
  client.once('end',()=>{closingClients.delete(closed);resolve();});
 });
 pool.end=async()=>{await end();await Promise.all([...closingClients]);};
 return pool;
}
export const createTestPool=options=>trackTestPoolClosure(new pg.Pool(options));

export async function verifyIdlePoolReconnect(pool, observer) {
 const readIdentity = async () => {
  const result = await pool.query(`
   SELECT pg_backend_pid() AS pid, current_database() AS database, current_user AS username
  `);
  return result.rows[0];
 };
 const before = await readIdentity();
 if (!/^(?:prc_http_[0-9]+_[a-f0-9]{32}_test|sr_anchor_tls_[a-f0-9]{32})$/u.test(before.database)) {
  throw Error('disposable_test_database_required');
 }
 const disconnected = once(pool, 'error', {signal:AbortSignal.timeout(10_000)});
 const interrupt = observer.query(`
  SELECT pg_terminate_backend(pid) AS terminated
  FROM pg_stat_activity WHERE pid=$1 AND datname=$2 AND usename=$3 AND state='idle'
 `, [before.pid, before.database, before.username]).then(result => {
  assert.equal(result.rows[0]?.terminated, true);
 });
 await Promise.all([disconnected, interrupt]);
 assert.notEqual((await readIdentity()).pid, before.pid);
}
