const fs = require('fs/promises');
const path = require('path');

const ncc = require('@vercel/ncc');

const entries = [
  { input: 'index.js', output: 'dist/index.js' },
  { input: 'post.js', output: 'dist/post.js' },
];

const legacyOutputs = ['index.js', 'post.js'];

async function buildEntry({ input, output }) {
  const inputPath = path.join(__dirname, input);
  const outputPath = path.join(__dirname, '..', output);
  const { code, assets } = await ncc(inputPath, {
    minify: false,
    sourceMap: false,
  });

  const assetNames = Object.keys(assets);
  if (assetNames.length > 0) {
    throw new Error(`Unexpected bundled assets for ${input}: ${assetNames.join(', ')}`);
  }

  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, code, 'utf8');
}

async function main() {
  await Promise.all(
    legacyOutputs.map((output) => fs.rm(path.join(__dirname, '..', output), { force: true }))
  );

  for (const entry of entries) {
    await buildEntry(entry);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});