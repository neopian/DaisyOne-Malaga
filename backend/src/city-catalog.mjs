import {readFileSync} from 'node:fs';

// Only this editable catalog defines new selectable places. It is a proposal,
// not launch approval, a geographic service boundary, or guide availability.
export const cityCatalog=JSON.parse(readFileSync(new URL('../../config/cities.json',import.meta.url),'utf8'));
export const knownPlaces=cityCatalog.cities;

/** Shared country/city key: accent-, punctuation-, spacing- and case-insensitive. */
export function normalizeLocation(value) {
 return typeof value==='string'?value.normalize('NFD').replace(/[\u0300-\u036f]/g,'').normalize('NFC').toLowerCase().replace(/[^a-z0-9\uac00-\ud7a3]/g,''):'';
}
export const locationAliases={countries:Object.create(null),cities:Object.create(null)};
const byId=new Map();
for(const place of knownPlaces) {
 if(byId.has(place.id))throw new Error(`Duplicate city identifier: ${place.id}`);
 byId.set(place.id,place);
 for(const alias of [place.countryCode,place.country,place.countryKo,...place.countryAliases]) {
  const key=normalizeLocation(alias),existing=locationAliases.countries[key];
  if(existing&&existing!==place.countryCode)throw new Error(`Ambiguous country alias: ${alias}`);
  locationAliases.countries[key]=place.countryCode;
 }
 for(const alias of [place.city,place.cityKo,place.nativeName,...place.aliases]) {
  const key=`${place.countryCode}:${normalizeLocation(alias)}`,existing=locationAliases.cities[key];
  if(existing&&existing!==place.id)throw new Error(`Ambiguous city alias: ${alias}`);
  locationAliases.cities[key]=place.id;
 }
}
export function findCity(country,city) {
 const code=locationAliases.countries[normalizeLocation(country)];
 return byId.get(locationAliases.cities[`${code}:${normalizeLocation(city)}`])??null;
}
export const isSupportedLocation=(country,city)=>findCity(country,city)!==null;

/** Match legacy rows without rewriting them or validating their current coverage. */
export function locationIdentity(country,city) {
 const countryCode=locationAliases.countries[normalizeLocation(country)];
 const known=countryCode?locationAliases.cities[`${countryCode}:${normalizeLocation(city)}`]:null;
 // Unknown historical places are opaque identities, not catalog search terms.
 // Keep non-Latin text and punctuation; encode both components without an
 // ambiguous delimiter. This must agree with PostgreSQL location_identity.
 const legacy=value=>value.normalize('NFC').trim();
 return known??`legacy:${JSON.stringify([countryCode??legacy(country),legacy(city)])}`;
}
export function nearestSupported({latitude,longitude,maxDistanceKm=cityCatalog.associationMaxDistanceKm}) {
 if(!Number.isFinite(latitude)||!Number.isFinite(longitude)||Math.abs(latitude)>90||Math.abs(longitude)>180||!Number.isFinite(maxDistanceKm)||maxDistanceKm<0)return null;
 const radians=value=>value*Math.PI/180;
 let nearest=null,minimum=maxDistanceKm;
 for(const place of knownPlaces) {
  const dLat=radians(place.latitude-latitude),dLon=radians(place.longitude-longitude);
  const a=Math.sin(dLat/2)**2+Math.cos(radians(latitude))*Math.cos(radians(place.latitude))*Math.sin(dLon/2)**2;
  const distance=6371*2*Math.asin(Math.sqrt(Math.min(1,Math.max(0,a))));
  if(distance<=minimum){nearest=place;minimum=distance;}
 }
 return nearest;
}
