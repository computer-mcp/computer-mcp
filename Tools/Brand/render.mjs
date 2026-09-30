import { readFile, writeFile } from "node:fs/promises";
import { release } from "node:os";
import sharp from "sharp";

const jobs = JSON.parse(await readFile(process.argv[2], "utf8"));
for (const { source, destination, width, height } of jobs) {
  const input = await readFile(source);
  await sharp(input, { density: 144 })
    .resize(width, height)
    .png({ compressionLevel: 9, adaptiveFiltering: false, palette: false })
    .toFile(destination);
}
await writeFile(process.argv[3], JSON.stringify({
  ...sharp.versions,
  node: process.version,
  platform: process.platform,
  architecture: process.arch,
  os_release: release(),
  locale: process.env.LC_ALL,
}, null, 2) + "\n");
