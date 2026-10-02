// Web-standard crypto: usable by Node and the isolated browser demo adapter.
const encoder = new TextEncoder();
export const randomId = () => crypto.randomUUID();
export function toBase64(bytes) { return btoa(Array.from(bytes, x => String.fromCharCode(x)).join('')); }
export function fromBase64(text) { return Uint8Array.from(atob(text), x => x.charCodeAt(0)); }
export function randomToken() { return toBase64(crypto.getRandomValues(new Uint8Array(32))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,''); }
export async function sha256(value) { return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))), n => n.toString(16).padStart(2,'0')).join(''); }
const iterations = 600_000;
async function derive(password, salt, count) {
 const key = await crypto.subtle.importKey('raw',encoder.encode(password),'PBKDF2',false,['deriveBits']);
 return new Uint8Array(await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt,iterations:count},key,256));
}
export async function hashPassword(password) {
 const salt = crypto.getRandomValues(new Uint8Array(16));
 return `pbkdf2_sha256$${iterations}$${toBase64(salt)}$${toBase64(await derive(password,salt,iterations))}`;
}
export async function verifyPassword(password, encoded) {
 const [scheme,count,salt,expected] = encoded.split('$');
 if (scheme !== 'pbkdf2_sha256' || Number(count) !== iterations) return false;
 const actual = await derive(password,fromBase64(salt),iterations), target = fromBase64(expected);
 let difference = actual.length ^ target.length;
 for(let i=0;i<actual.length;i++) difference |= actual[i] ^ target[i];
 return difference === 0;
}
export async function sign(secret,value) {
 const key = await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return toBase64(new Uint8Array(await crypto.subtle.sign('HMAC',key,encoder.encode(value)))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
}
export async function verifySignature(secret,value,signature) {
 try {
  const key = await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify']);
  return crypto.subtle.verify('HMAC',key,fromBase64(signature.replaceAll('-','+').replaceAll('_','/')),encoder.encode(value));
 } catch { return false; }
}
async function encryptionKey(secret) {
 const bytes=await crypto.subtle.digest('SHA-256',encoder.encode(`daisy-auth-replay:${secret}`));
 return crypto.subtle.importKey('raw',bytes,'AES-GCM',false,['encrypt','decrypt']);
}
export async function seal(secret,value,associatedData) {
 const iv=crypto.getRandomValues(new Uint8Array(12));
 const bytes=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(associatedData)},await encryptionKey(secret),encoder.encode(JSON.stringify(value)));
 return `${toBase64(iv)}.${toBase64(new Uint8Array(bytes))}`;
}
export async function unseal(secret,value,associatedData) {
 const [iv,bytes]=value.split('.');
 const plaintext=await crypto.subtle.decrypt({name:'AES-GCM',iv:fromBase64(iv),additionalData:encoder.encode(associatedData)},await encryptionKey(secret),fromBase64(bytes));
 return JSON.parse(new TextDecoder().decode(plaintext));
}
