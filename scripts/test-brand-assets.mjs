import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { inflateSync } from "node:zlib";

const root = resolve(import.meta.dirname, "..");
const source = await readFile(
  resolve(root, "assets", "branding", "devpulse-mark.svg"),
  "utf8",
);
const generator = await readFile(
  resolve(root, "scripts", "generate-brand-assets.mjs"),
  "utf8",
);
const tauriConfig = JSON.parse(
  await readFile(
    resolve(root, "apps", "desktop", "src-tauri", "tauri.conf.json"),
    "utf8",
  ),
);
const iconDirectory = resolve(root, "apps", "desktop", "src-tauri", "icons");

assert.match(source, /aria-label="DevPulse pulse aperture mark"/);
assert.match(
  source,
  /#008F84/i,
  "The principal signal teal must remain the mark's dominant colour.",
);
assert.match(
  source,
  /#B7D94B/i,
  "The small pulse-lime energy cue must remain present.",
);
assert.match(
  source,
  /fill-rule="evenodd"/,
  "The pulse must be a true transparent aperture, not a dark painted detail.",
);
assert.match(
  source,
  /id="split-signal-aperture"/,
  "The mark must use the abstract split-signal aperture.",
);
assert.equal(
  (source.match(/stroke="#000"/g) ?? []).length,
  2,
  "The aperture must be two separate signal channels, never one continuous heartbeat line.",
);
assert.equal(
  (source.match(/stroke-width="52"/g) ?? []).length,
  2,
  "The opposing signal channels must carry equal visual weight.",
);
assert.match(
  source,
  /<circle cx="256" cy="256" r="18" fill="#B7D94B"/,
  "The energy cue must sit in the central signal handoff.",
);
assert.doesNotMatch(
  source,
  /M104 270h78l53-106 66 182 47-104h64/,
  "The retired continuous ECG aperture must not return.",
);
assert.equal(
  (source.match(/#B7D94B/gi) ?? []).length,
  1,
  "Pulse-lime is reserved for one small energy cue.",
);
assert.doesNotMatch(
  source,
  /<rect\b/i,
  "The mark must not use an opaque canvas background.",
);
assert.doesNotMatch(
  source,
  /interim/i,
  "The shipped mark must not retain interim identity text.",
);
assert.doesNotMatch(
  generator,
  /const source\s*=/,
  "The SVG file must be the sole editable source of truth.",
);
assert.doesNotMatch(
  generator,
  /writeFile\(sourcePath/,
  "Asset generation must not overwrite the source SVG.",
);

for (const [name, expectedSize] of [
  ["32x32.png", 32],
  ["128x128.png", 128],
  ["128x128@2x.png", 256],
]) {
  const png = await readFile(resolve(iconDirectory, name));
  const decoded = decodeRgbaPng(png);
  assert.equal(decoded.width, expectedSize, `${name} has the wrong width.`);
  assert.equal(decoded.height, expectedSize, `${name} has the wrong height.`);
  assert.ok(
    decoded.alpha.some((value) => value === 0),
    `${name} must retain transparent canvas pixels.`,
  );
  assert.ok(
    decoded.alpha.some((value) => value === 255),
    `${name} must retain fully opaque mark pixels.`,
  );
}

const ico = await readFile(resolve(iconDirectory, "icon.ico"));
assert.equal(ico.readUInt16LE(0), 0, "The ICO reserved word must be zero.");
assert.equal(ico.readUInt16LE(2), 1, "The Windows asset must be an icon.");
const icoSizes = Array.from({ length: ico.readUInt16LE(4) }, (_, index) => {
  const width = ico[6 + index * 16];
  const height = ico[7 + index * 16];
  assert.equal(width, height, "Every ICO frame must be square.");
  return width === 0 ? 256 : width;
});
assert.deepEqual(
  [...new Set(icoSizes)].sort((left, right) => left - right),
  [16, 24, 32, 48, 64, 256],
  "The ICO must cover every supported Windows shell size.",
);
assert.equal(
  tauriConfig.bundle.windows.nsis.installerIcon,
  "icons/icon.ico",
  "The NSIS installer executable must carry the DevPulse Windows icon.",
);
assert.equal(
  tauriConfig.bundle.windows.nsis.uninstallerIcon,
  "icons/icon.ico",
  "The NSIS uninstaller must carry the DevPulse Windows icon.",
);

console.log("DevPulse brand source contract passed.");

function decodeRgbaPng(png) {
  assert.deepEqual(
    [...png.subarray(0, 8)],
    [137, 80, 78, 71, 13, 10, 26, 10],
    "The generated asset must be a PNG.",
  );
  let offset = 8;
  let width = 0;
  let height = 0;
  const imageData = [];
  while (offset < png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.toString("ascii", offset + 4, offset + 8);
    const data = png.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      assert.equal(data[8], 8, "Generated PNGs must use 8-bit channels.");
      assert.equal(data[9], 6, "Generated PNGs must use RGBA colour.");
    } else if (type === "IDAT") {
      imageData.push(data);
    } else if (type === "IEND") {
      break;
    }
    offset += length + 12;
  }
  assert.ok(width > 0 && height > 0 && imageData.length > 0);
  const packed = inflateSync(Buffer.concat(imageData));
  const stride = width * 4;
  const previous = Buffer.alloc(stride);
  const current = Buffer.alloc(stride);
  const alpha = [];
  let sourceOffset = 0;
  for (let row = 0; row < height; row += 1) {
    const filter = packed[sourceOffset++];
    for (let column = 0; column < stride; column += 1) {
      const source = packed[sourceOffset++];
      const left = column >= 4 ? current[column - 4] : 0;
      const up = previous[column];
      const upperLeft = column >= 4 ? previous[column - 4] : 0;
      current[column] =
        (source + pngFilterDelta(filter, left, up, upperLeft)) & 0xff;
    }
    for (let column = 3; column < stride; column += 4) {
      alpha.push(current[column]);
    }
    current.copy(previous);
  }
  return { width, height, alpha };
}

function pngFilterDelta(filter, left, up, upperLeft) {
  if (filter === 0) return 0;
  if (filter === 1) return left;
  if (filter === 2) return up;
  if (filter === 3) return Math.floor((left + up) / 2);
  if (filter === 4) {
    const prediction = left + up - upperLeft;
    const leftDistance = Math.abs(prediction - left);
    const upDistance = Math.abs(prediction - up);
    const upperLeftDistance = Math.abs(prediction - upperLeft);
    if (leftDistance <= upDistance && leftDistance <= upperLeftDistance)
      return left;
    return upDistance <= upperLeftDistance ? up : upperLeft;
  }
  throw new Error(`Unsupported PNG filter ${filter}.`);
}
