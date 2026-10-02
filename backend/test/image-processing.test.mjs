import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import {sanitizeImage,ImageProcessingError,MAX_IMAGE_BYTES,MAX_IMAGE_PIXELS} from '../src/image-processing.mjs';
import {metadataPhoto,invalidPhotos,privateMarker} from './image-fixtures.mjs';

test('JPEG, PNG and WebP retain valid pixels and remove actual EXIF/GPS/XMP/ICC payloads',async t=>{
 for(const format of ['jpeg','png','webp'])await t.test(format,async()=>{
  const input=await metadataPhoto(format),before=await sharp(input).metadata();
  assert.equal(before.orientation,6);assert.ok(before.exif?.length);assert.ok(before.xmp?.length);assert.ok(before.icc?.length);assert.ok(input.includes(Buffer.from(privateMarker)));
  const result=await sanitizeImage({bytes:input,mime:`image/${format}`}),after=await sharp(result.bytes).metadata();
  assert.equal(result.mime,`image/${format}`);assert.equal(after.format,format);assert.deepEqual([after.width,after.height],[8,12]);
  for(const name of ['exif','xmp','iptc','icc','orientation'])assert.equal(after[name],undefined,`${format} retains ${name}`);
  assert.equal(result.bytes.includes(Buffer.from(privateMarker)),false);
  const pixels=await sharp(result.bytes,{failOn:'warning'}).raw().toBuffer();assert.ok(pixels.length>0);assert.ok(result.bytes.length<=MAX_IMAGE_BYTES);
  if(format!=='jpeg'){assert.equal(after.hasAlpha,true);assert.equal(pixels[3],128);}
 });
});

test('all EXIF rotations and mirrored orientations are applied without resizing or cropping',async()=>{
 const colors=[[240,0,0],[0,240,0],[0,0,240],[240,240,0],[0,240,240],[240,0,240]];
 const expected={1:[0,1,2,3,4,5],2:[1,0,3,2,5,4],3:[5,4,3,2,1,0],4:[4,5,2,3,0,1],5:[0,2,4,1,3,5],6:[4,2,0,5,3,1],7:[5,3,1,4,2,0],8:[1,3,5,0,2,4]};
 for(let orientation=1;orientation<=8;orientation++){
  const input=await sharp(Buffer.from(colors.flat()),{raw:{width:2,height:3,channels:3}}).png().withMetadata({orientation}).toBuffer();
  const {bytes}=await sanitizeImage({bytes:input,mime:'image/png'}),{data,info}=await sharp(bytes).raw().toBuffer({resolveWithObject:true});
  assert.deepEqual([info.width,info.height],orientation<5?[2,3]:[3,2]);assert.deepEqual(data,Buffer.from(expected[orientation].flatMap(i=>colors[i])),`orientation ${orientation}`);
 }
});

test('16-bit PNG retains its sample depth instead of quantizing to 8-bit',async()=>{
 const input=await sharp({create:{width:3,height:2,channels:4,background:{r:47,g:123,b:239,alpha:0.5}}}).toColourspace('rgb16').png().toBuffer();
 assert.equal((await sharp(input).metadata()).bitsPerSample,16);
 const {bytes}=await sanitizeImage({bytes:input,mime:'image/png'});assert.equal((await sharp(bytes).metadata()).bitsPerSample,16);
 assert.deepEqual(await sharp(bytes).raw({depth:'ushort'}).toBuffer(),await sharp(input).raw({depth:'ushort'}).toBuffer());
});

test('strict codecs reject malformed content, declared pixel bombs, animation and output expansion',async t=>{
 for(const entry of await invalidPhotos())await t.test(entry.name,()=>assert.rejects(sanitizeImage(entry),error=>error instanceof ImageProcessingError&&error.status===400&&error.code==='INVALID_IMAGE'));
 assert.equal(MAX_IMAGE_PIXELS,20_000_000);
 for(const entry of [{bytes:Buffer.alloc(0),mime:'image/png'},{bytes:Buffer.alloc(MAX_IMAGE_BYTES+1),mime:'image/png'},{bytes:Buffer.from('<svg/>'),mime:'image/svg+xml'}])await assert.rejects(sanitizeImage(entry),{code:'INVALID_IMAGE'});
});

test('processing capacity is bounded and errors release slots for subsequent uploads',async()=>{
 const bytes=await metadataPhoto('png');
 const results=await Promise.allSettled(Array.from({length:24},()=>sanitizeImage({bytes,mime:'image/png'})));
 assert.equal(results.filter(r=>r.status==='fulfilled').length,10);
 const rejected=results.filter(r=>r.status==='rejected');assert.equal(rejected.length,14);
 for(const result of rejected){assert.equal(result.reason.code,'IMAGE_PROCESSING_BUSY');assert.equal(result.reason.status,503);}
 assert.ok((await sanitizeImage({bytes,mime:'image/png'})).bytes.length);
});
