// Run after npm ci in this folder. No dependency is fetched at app runtime.
import { build } from 'esbuild';
import { readFile, writeFile, mkdir, cp, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const out = path.join(root, 'Resources/markdown-viewer/vendor');
const nm = path.join(here, 'node_modules');
await mkdir(out, { recursive: true });
await build({ entryPoints:[path.join(here,'markdown-entry.js')], outfile:path.join(out,'markdown.js'), bundle:true, minify:true, format:'iife', legalComments:'eof' });
for (const [pkg, src, dst] of [
  ['mermaid','dist/mermaid.min.js','mermaid.min.js'],
  ['@highlightjs/cdn-assets','highlight.min.js','highlight.min.js'],
  ['dompurify','dist/purify.min.js','purify.min.js'],
  ['katex','dist/katex.min.js','katex/katex.min.js'],
  ['katex','dist/katex.min.css','katex/katex.min.css'],
  ['katex','dist/fonts','katex/fonts'],
]) { await mkdir(path.dirname(path.join(out,dst)),{recursive:true}); await cp(path.join(nm,pkg,src),path.join(out,dst),{recursive:true}); }
let css='';
for (const [name, styles] of [['literata',['opsz.css','opsz-italic.css']],['jetbrains-mono',['index.css']],['inter',['opsz.css']]]) {
  const pkg=path.join(nm,'@fontsource-variable',name);
  for (const style of styles) {
    const text=await readFile(path.join(pkg,style),'utf8');
    for (const [,file] of text.matchAll(/url\(\.\/files\/([^)]+)\)/g)) {
      await mkdir(path.join(out,'fonts'),{recursive:true});
      await cp(path.join(pkg,'files',file),path.join(out,'fonts',file));
    }
    css+=text.replaceAll('./files/','./fonts/')+'\n';
  }
}
await writeFile(path.join(out,'fonts.css'),css);
const manifest={};
let licenses='\n\n---\n\n## Bundled markdown viewer\n\nPinned npm sources and file hashes: `Resources/markdown-viewer/vendor/MANIFEST.json`.\n\n';
const pkgs=['markdown-it','markdown-it-anchor','markdown-it-footnote','markdown-it-task-lists','mermaid','@highlightjs/cdn-assets','katex','dompurify','@fontsource-variable/literata','@fontsource-variable/jetbrains-mono','@fontsource-variable/inter'];
for (const pkg of pkgs) {
  const dir=path.join(nm,pkg), meta=JSON.parse(await readFile(path.join(dir,'package.json'),'utf8'));
  manifest[pkg]={version:meta.version,source:`https://registry.npmjs.org/${pkg}/-/${pkg.split('/').at(-1)}-${meta.version}.tgz`,license:meta.license};
}
// Include notices for transitive code in browser distributions and our parser bundle.
async function notices(dir,prefix='') {
  for(const e of await readdir(dir,{withFileTypes:true})) {
    if(e.name.startsWith('.')) continue;
    const f=path.join(dir,e.name);
    if(e.isDirectory() && (e.name.startsWith('@') || prefix==='' || prefix.startsWith('@')&&prefix.split('/').length===2)) await notices(f,prefix+e.name+'/');
    else if(e.isFile() && /^(licen[sc]e|copying|notice)(\.|$)/i.test(e.name)) {
      const text=await readFile(f,'utf8');
      licenses+=`### ${prefix}${e.name}\n\n\`\`\`text\n${text.replace(/\r\n?/g,'\n').split('\n').map(line=>line.trimEnd()).join('\n').trim()}\n\`\`\`\n\n`;
    }
  }
}
await notices(nm);
const files={};
async function hashes(dir) { for(const e of await readdir(dir,{withFileTypes:true})) {
  const f=path.join(dir,e.name); if(e.isDirectory()) await hashes(f);
  else if(e.name!=='MANIFEST.json') files[path.relative(out,f)]=createHash('sha256').update(await readFile(f)).digest('hex');
}}
await hashes(out);
await writeFile(path.join(out,'MANIFEST.json'),JSON.stringify({packages:manifest,files},null,2)+'\n');
const licenseFile=path.join(root,'THIRD_PARTY_LICENSES.md');
const previous=(await readFile(licenseFile,'utf8')).split('\n\n---\n\n## Bundled markdown viewer')[0];
await writeFile(licenseFile,previous+licenses.trimEnd()+'\n');
