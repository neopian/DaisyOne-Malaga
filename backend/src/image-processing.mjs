import sharp from 'sharp';

export const MAX_IMAGE_BYTES=3*1024*1024;
export const MAX_IMAGE_PIXELS=20_000_000;
const formats={'image/jpeg':'jpeg','image/png':'png','image/webp':'webp'};
const inputOptions={failOn:'warning',limitInputPixels:MAX_IMAGE_PIXELS,limitInputChannels:4,unlimited:false,sequentialRead:true};

export class ImageProcessingError extends Error {
 constructor(message,{status=400,code='INVALID_IMAGE'}={}) {super(message);this.status=status;this.code=code;}
}
const invalid=message=>{throw new ImageProcessingError(message);};

// A process-wide bound also covers separate API instances. Queued uploads retain
// encoded bytes only; a request's five photos are decoded one at a time.
let active=0;
const waiting=[];
async function acquire() {
 if(active<2){active++;return;}
 if(waiting.length>=8)throw new ImageProcessingError('Photo processing is busy. Try again shortly.',{status:503,code:'IMAGE_PROCESSING_BUSY'});
 await new Promise(resolve=>waiting.push(resolve));
}
function release(){const next=waiting.shift();if(next)next();else active--;}

function inspectContainer(bytes,mime) {
 if(mime==='image/jpeg') {
  if(bytes.length<3||bytes[0]!==255||bytes[1]!==216||bytes[2]!==255)invalid('Image content does not match its MIME type.');
  return;
 }
 if(mime==='image/png') {
  if(bytes.length<8||!bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))invalid('Image content does not match its MIME type.');
  // libpng may read APNG as an ordinary first-frame PNG; reject its animation
  // control chunk explicitly rather than silently discarding remaining frames.
  for(let offset=8;offset<bytes.length;) {
   if(offset+12>bytes.length)invalid('Malformed PNG image.');
   const size=bytes.readUInt32BE(offset),end=offset+12+size,type=bytes.toString('ascii',offset+4,offset+8);
   if(end>bytes.length)invalid('Malformed PNG image.');
   if(['acTL','fcTL','fdAT'].includes(type))invalid('Animated photos are not supported. Choose a still image.');
   if(type==='IEND')return;
   offset=end;
  }
  invalid('Malformed PNG image.');
 }
 if(bytes.length<12||bytes.toString('ascii',0,4)!=='RIFF'||bytes.toString('ascii',8,12)!=='WEBP')invalid('Image content does not match its MIME type.');
 const end=bytes.readUInt32LE(4)+8;
 if(end!==bytes.length)invalid('Malformed WebP image.');
 for(let offset=12;offset<end;) {
  if(offset+8>end)invalid('Malformed WebP image.');
  const size=bytes.readUInt32LE(offset+4),next=offset+8+size+(size%2),type=bytes.toString('ascii',offset,offset+4);
  if(next>end)invalid('Malformed WebP image.');
  if(type==='ANIM'||type==='ANMF'||(type==='VP8X'&&size>0&&(bytes[offset+8]&2)))invalid('Animated photos are not supported. Choose a still image.');
  offset=next;
 }
}

/** Decode untrusted photos and return only freshly encoded, metadata-free bytes.
 * No original-byte fallback is allowed, including in development. Sharp applies
 * colour conversion to sRGB and drops EXIF/GPS/XMP/IPTC/ICC metadata by default.
 * EXIF rotation/mirroring is applied to pixels before the orientation is removed.
 */
export async function sanitizeImage({bytes,mime}) {
 if(!(bytes instanceof Uint8Array)||!bytes.length||bytes.length>MAX_IMAGE_BYTES)invalid('Invalid or oversized image (maximum 3 MiB).');
 if(!Object.hasOwn(formats,mime))invalid('Use a JPEG, PNG, or WebP image.');
 const input=Buffer.from(bytes.buffer,bytes.byteOffset,bytes.byteLength);
 inspectContainer(input,mime);
 await acquire();
 try {
  const pipeline=sharp(input,inputOptions).timeout({seconds:10});
  const metadata=await pipeline.metadata();
  if(metadata.format!==formats[mime])invalid('Image content does not match its MIME type.');
  if(!Number.isSafeInteger(metadata.width)||!Number.isSafeInteger(metadata.height)||metadata.width<1||metadata.height<1||metadata.width*metadata.height>MAX_IMAGE_PIXELS)invalid('Photo dimensions exceed the 20 megapixel limit.');
  if((metadata.pages??1)!==1)invalid('Animated photos are not supported. Choose a still image.');
  pipeline.autoOrient();
  // Preserve dimensions and transparency. PNG/WebP introduce no extra lossy
  // compression; JPEG uses high quality with no additional chroma subsampling.
  if(mime==='image/jpeg')pipeline.jpeg({quality:95,chromaSubsampling:'4:4:4'});
  else if(mime==='image/png'){
   if(metadata.depth==='ushort')pipeline.toColourspace('rgb16');
   pipeline.png({compressionLevel:6});
  }
  else pipeline.webp({lossless:true,effort:2});
  const {data,info}=await pipeline.toBuffer({resolveWithObject:true});
  if(!data.length||data.length>MAX_IMAGE_BYTES)invalid('The processed photo exceeds 3 MiB. Choose a smaller image.');
  if(info.width*info.height>MAX_IMAGE_PIXELS||info.format!==formats[mime])invalid('Invalid processed photo.');
  return {bytes:data,mime};
 } catch(error) {
  if(error instanceof ImageProcessingError)throw error;
  throw new ImageProcessingError('The photo could not be decoded safely. Choose a valid JPEG, PNG, or WebP under 20 megapixels.');
 } finally {release();}
}
