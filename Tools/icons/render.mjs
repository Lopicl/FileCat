// Renders the flat, full-bleed artwork (FileCat.svg, MusiCat.svg) to an opaque RGB PNG, for
// places that need a plain square image, like the AltStore source's iconURL. The apps' own
// icons are the Icon Composer files FileCat/FileCat/AppIcon.icon and MusiCat/MusiCat/AppIcon.icon.
// Usage: cd Tools/icons && npm install --no-save @resvg/resvg-js && node render.mjs MusiCat.svg out.png [size]
import { Resvg } from '@resvg/resvg-js'
import { readFileSync, writeFileSync } from 'fs'
import { deflateSync } from 'zlib'

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})
function crc32(bytes) {
  let c = 0xffffffff
  for (const b of bytes) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length)
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body))
  return Buffer.concat([length, body, crc])
}
// The icons are opaque, so dropping the alpha byte loses nothing.
function rgbPNG(rgba, width, height) {
  const rows = Buffer.alloc(height * (width * 3 + 1))
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1)
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4, o = row + 1 + x * 3
      rows[o] = rgba[i]; rows[o + 1] = rgba[i + 1]; rows[o + 2] = rgba[i + 2]
    }
  }
  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4)
  header[8] = 8; header[9] = 2 // 8-bit RGB
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(rows, { level: 9 })), chunk('IEND', Buffer.alloc(0))])
}

const [,, svg, output, size = '1024'] = process.argv
const image = new Resvg(readFileSync(svg, 'utf8'), { fitTo: { mode: 'width', value: Number(size) } }).render()
writeFileSync(output, rgbPNG(image.pixels, image.width, image.height))
