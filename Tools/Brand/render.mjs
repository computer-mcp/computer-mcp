import { readFile, writeFile } from "node:fs/promises";
import sharp from "sharp";

const jobs = JSON.parse(await readFile(process.argv[2], "utf8"));
for (const { source, destination, width, height } of jobs) {
  const input = await readFile(source);
  await sharp(input, { density: 144 })
    .resize(width, height)
    .png({ compressionLevel: 9, adaptiveFiltering: false, palette: false })
    .toFile(destination);
}
await writeFile(process.argv[3], JSON.stringify(sharp.versions, null, 2) + "\n");
