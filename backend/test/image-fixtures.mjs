// Synthetic pixels only. No real photographs, locations, or personal metadata.
import sharp from 'sharp';

export const privateMarker='SYNTHETIC-METADATA-DO-NOT-RETAIN';
export async function metadataPhoto(format='jpeg',orientation=6) {
 return sharp({create:{width:12,height:8,channels:4,background:{r:230,g:40,b:15,alpha:0.5}}})
  .withExif({IFD0:{Artist:privateMarker,ImageDescription:privateMarker},IFD3:{GPSLatitudeRef:'N',GPSLatitude:'51/1 30/1 3230/100',GPSLongitudeRef:'W',GPSLongitude:'0/1 7/1 4366/100'}})
  .withXmp(`<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:creator="${privateMarker}"/></rdf:RDF></x:xmpmeta>`)
  .withMetadata({orientation})[format]().toBuffer();
}

function crc32(bytes) {let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
function chunk(type,payload) {const bytes=Buffer.alloc(payload.length+12);bytes.writeUInt32BE(payload.length,0);bytes.write(type,4,4,'ascii');payload.copy(bytes,8);bytes.writeUInt32BE(crc32(bytes.subarray(4,-4)),bytes.length-4);return bytes;}

export async function excessivePixelPhoto() {
 const bytes=await sharp({create:{width:1,height:1,channels:3,background:'red'}}).png().toBuffer();
 // Alter only the header, with a valid CRC: the pixel limit must reject this
 // before attempting to expand any maliciously declared image dimensions.
 bytes.writeUInt32BE(20001,16);bytes.writeUInt32BE(1000,20);bytes.writeUInt32BE(crc32(bytes.subarray(12,29)),29);return bytes;
}
export async function animatedPng() {
 const bytes=await sharp({create:{width:1,height:1,channels:4,background:'red'}}).png().toBuffer();
 const control=Buffer.alloc(8);control.writeUInt32BE(1);
 const frame=Buffer.alloc(26);frame.writeUInt32BE(1,4);frame.writeUInt32BE(1,8);frame.writeUInt16BE(1,20);frame.writeUInt16BE(10,22);
 return Buffer.concat([bytes.subarray(0,33),chunk('acTL',control),chunk('fcTL',frame),bytes.subarray(33)]);
}
export async function animatedWebp() {
 const one=await sharp({create:{width:2,height:2,channels:3,background:'red'}}).png().toBuffer();
 const two=await sharp({create:{width:2,height:2,channels:3,background:'blue'}}).png().toBuffer();
 return sharp([one,two],{join:{animated:true}}).webp().toBuffer();
}
export async function excessiveOutputPhoto() {
 let state=1731;const raw=Buffer.alloc(2000*1600*3);
 for(let i=0;i<raw.length;i++){state^=state<<13;state^=state>>>17;state^=state<<5;raw[i]=state&255;}
 return sharp(raw,{raw:{width:2000,height:1600,channels:3}}).jpeg({quality:85}).toBuffer();
}

export async function invalidPhotos() {
 const png=await metadataPhoto('png'),jpeg=await metadataPhoto('jpeg');
 return [
  {name:'wrong-mime',bytes:png,mime:'image/jpeg'},
  {name:'signature-only-png',bytes:png.subarray(0,8),mime:'image/png'},
  {name:'signature-only-jpeg',bytes:Buffer.from([255,216,255,1,2,3]),mime:'image/jpeg'},
  {name:'signature-only-webp',bytes:Buffer.from('RIFF\0\0\0\0WEBP'),mime:'image/webp'},
  {name:'truncated-jpeg',bytes:jpeg.subarray(0,jpeg.length-20),mime:'image/jpeg'},
  {name:'truncated-png',bytes:png.subarray(0,png.length-20),mime:'image/png'},
  {name:'corrupt-png-pixels',bytes:Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmWQAAAAASUVORK5CYII=','base64'),mime:'image/png'},
  {name:'pixel-bomb',bytes:await excessivePixelPhoto(),mime:'image/png'},
  {name:'animated-png',bytes:await animatedPng(),mime:'image/png'},
  {name:'animated-webp',bytes:await animatedWebp(),mime:'image/webp'},
  {name:'oversized-after-processing',bytes:await excessiveOutputPhoto(),mime:'image/jpeg'},
 ];
}
