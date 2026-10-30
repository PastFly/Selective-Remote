import pg from 'pg';

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
