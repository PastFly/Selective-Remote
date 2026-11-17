import {normalizeEmail} from './security.mjs';

// Optional operator restriction for the two fresh accounts in a staging run.
// It cannot enable registration itself and never applies to production config.
export function stagingRegistrationEmails(value,environment) {
  if(value===undefined)return null;
  const fail=()=>{throw Error('STAGING_REGISTRATION_EMAIL_ALLOWLIST must contain exactly two canonical staging emails');};
  if(environment!=='staging'||typeof value!=='string')fail();
  const emails=value.split(',');
  if(emails.length!==2||new Set(emails).size!==2)fail();
  for(const email of emails){
    try{if(email!==normalizeEmail(email))fail();}catch{fail();}
  }
  return Object.freeze(emails);
}
