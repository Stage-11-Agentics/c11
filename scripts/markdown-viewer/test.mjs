import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, readdir, mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const bundle=path.join(root,'Resources/markdown-viewer');
const output=process.env.C11_MD_EVIDENCE || path.join(os.tmpdir(),'c11-md-358-evidence');
await mkdir(output,{recursive:true});
const temporary=await mkdtemp(path.join(os.tmpdir(),'c11-md-prototype-'));
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH}:{})});
const page=await browser.newPage({viewport:{width:1200,height:820}});
const errors=[],requests=[];
page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
page.on('pageerror',e=>errors.push(e.message));
page.on('request',r=>{if(!r.url().startsWith('file:')&&!r.url().startsWith('c11md-asset:'))requests.push(r.url());});
await page.addInitScript(()=>{window.testMessages=[];window.webkit={messageHandlers:{c11md:{postMessage:m=>window.testMessages.push(m)}}};});
const load=async(markdown,documentPath='/synthetic/reader.md',revision=1)=>page.evaluate(v=>c11md.load(v),{markdown,documentPath,baseURL:pathToFileURL(documentPath).href,revision});
const settings=async s=>page.evaluate(s=>c11md.setSettings(s),s);
const fixtures=path.join(root,'docs/design-prototypes/markdown-viewer/fixtures');
const files=(await readdir(fixtures)).filter(x=>x.endsWith('.md')).map(x=>path.join(fixtures,x));
files.push(path.join(root,'docs/c11-messaging-primitive-design.md'),path.join(root,'docs/design-prototypes/markdown-viewer/reader/specimen.md'));
const report={browser:await browser.version(),matrices:[],scenarios:[],screenshots:[],consoleErrors:errors,networkRequests:requests};
const scenario=(name,details={})=>{report.scenarios.push({name,...details});console.log('PASS '+name);};
try {
  await page.goto(pathToFileURL(path.join(bundle,'index.html')).href);
  await page.waitForFunction(()=>window.testMessages.some(m=>m.type==='ready'));
  for(const theme of ['light','dark'])for(const width of [560,820,1200]) {
    await page.setViewportSize({width,height:820});await settings({theme,scale:1,typeface:'serif',outlineOpen:'auto'});
    for(const file of files) {
      const markdown=await readFile(file,'utf8');await load(markdown,'/synthetic/'+path.basename(file));
      const result=await page.evaluate(()=>({heads:c11md.outline().length,figures:document.querySelectorAll('.diagram').length,svgs:document.querySelectorAll('.diagram svg').length,failed:document.querySelectorAll('.diagram-err').length,overflow:document.documentElement.scrollWidth>innerWidth}));
      assert.ok(result.heads>0,file);assert.equal(result.failed,0,`${file}: diagram failure`);assert.equal(result.figures,result.svgs,file);assert.equal(result.overflow,false,file);
      report.matrices.push({theme,width,file:path.relative(root,file),...result});
    }
  }
  scenario('7 fixtures at 560/820/1200 px in light/dark',{loads:report.matrices.length});
  const messaging=await readFile(path.join(root,'docs/c11-messaging-primitive-design.md'),'utf8');
  await load(messaging);assert.equal(await page.locator('.diagram svg').count(),7);scenario('messaging document: all 7 diagrams, including entity-bearing sequences');
  const specimen='---\ntitle: Synthetic reader\n---\n# Reader\n\nA footnote[^note], **bold**, $E=mc^2$ and [jump](#tasks).\n\n> [!NOTE]\n> Keep the reader’s place.\n\n## Tasks\n\n- [x] Complete\n- [ ] Pending\n\n| Key | Value | Notes |\n| --- | --- | --- |\n| One | Two | Three |\n\n```javascript\nconst answer = 42;\n```\n\n$$\n\\sum_{i=1}^{n} i\n$$\n\n```mermaid\nflowchart LR\n  A[Input] --> B[Output]\n```\n\n[^note]: A margin note.\n';
  await page.setViewportSize({width:1200,height:820});await load(specimen);
  assert.equal(await page.locator('.callout-note').count(),1);assert.equal(await page.locator('input:checked').count(),1);
  assert.equal(await page.locator('.katex').count(),2);assert.ok(await page.locator('.hljs-keyword').count()>0);assert.equal(await page.locator('.frontmatter').count(),1);
  assert.equal(await page.evaluate(()=>c11md.outline()[0].children[0].tasks),2);
  assert.equal(await page.locator('.sidenote').count(),1);
  await page.setViewportSize({width:560,height:820});await settings({scale:1});
  assert.equal(await page.locator('.table-wrap.reflow').count(),1);
  await page.locator('.fn-ref a').click();assert.equal(await page.locator('#note').isVisible(),true);
  await page.keyboard.press('Escape');assert.equal(await page.locator('#note').isVisible(),false);
  await page.locator('.copy').click();assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='copy').text),'const answer = 42;\n');
  await page.evaluate(()=>c11md.expandDiagram(1));assert.equal(await page.locator('#diagramOverlay').isVisible(),true);
  await page.locator('[data-zoom="1"]').click();assert.ok(await page.locator('#diagramZoom').evaluate(x=>x.style.transform.includes('1.25')));
  await page.locator('#diagramClose').click();assert.equal(await page.locator('#diagramOverlay').isVisible(),false);
  scenario('callouts, tasks/tree counts, math, highlighting/copy, frontmatter, responsive tables, margin/popover notes, diagram expansion');
  assert.equal(await page.evaluate(()=>c11md.find('keep the reader’s place').matches),1);
  assert.equal(await page.evaluate(()=>c11md.findNext().current),1);assert.equal(await page.evaluate(()=>c11md.findPrevious().current),1);await page.evaluate(()=>c11md.findClose());
  await load('# Find\n\nalpha **beta** gamma alpha beta gamma\n');
  assert.equal(await page.evaluate(()=>c11md.find('alpha beta').matches),2);assert.equal(await page.evaluate(()=>c11md.findNext().current),2);
  assert.equal(await page.evaluate(()=>c11md.findNext().current),1);assert.equal(await page.evaluate(()=>c11md.findPrevious().current),2);await page.evaluate(()=>c11md.findClose());
  scenario('literal find spans inline formatting, next/previous wrap, close clears marks');
  // The selected and visible block must remain the same node when a prior block grows.
  const long='# Anchor\n\n'+Array.from({length:60},(_,i)=>`## Section ${i}\n\nParagraph ${i}: `+'An anchored reader keeps this line in the same place. '.repeat(6)+'\n').join('\n');
  for(const width of [560,820,1200]) {
    await page.setViewportSize({width,height:820});await settings({theme:'light',typeface:'serif',scale:1});await load(long,'/synthetic/anchor.md',1);
    await page.evaluate(()=>{c11md.scrollToHeading('Section 30');window.witness=document.getElementById('c11md-h-section-30').nextElementSibling;
      window.diagramWitness=document.querySelector('.diagram svg');const range=document.createRange();range.selectNodeContents(witness);window.getSelection().removeAllRanges();window.getSelection().addRange(range);});
    const before=await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top);
    await load(long.replace('Paragraph 0:','An added block above the viewport.\n\nParagraph 0:'),'/synthetic/anchor.md',2);
    const after=await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top);
    assert.ok(Math.abs(before-after)<1,`anchor drift ${width}: ${before} -> ${after}`);
    assert.equal(await page.evaluate(()=>witness===document.getElementById('c11md-h-section-30').nextElementSibling),true);
    assert.ok((await page.evaluate(()=>window.getSelection().toString())).startsWith('Paragraph 30:'));
    await page.evaluate(()=>window.getSelection().removeAllRanges());
    for(const change of [{theme:'dark'},{typeface:'sans'},{typeface:'mono'},{typeface:'serif',scale:1.6},{outlineOpen:true},{outlineOpen:false}]) {
      const y=await page.locator('#c11md-h-section-30').evaluate(x=>{const r=document.createRange();r.selectNodeContents(x.lastChild);return r.getBoundingClientRect().top;});await settings(change);
      const z=await page.locator('#c11md-h-section-30').evaluate(x=>{const r=document.createRange();r.selectNodeContents(x.lastChild);return r.getBoundingClientRect().top;});assert.ok(Math.abs(y-z)<1,`settings anchor ${width} ${JSON.stringify(change)}: ${y} -> ${z}`);
    }
    const top=await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top);
    await page.evaluate(()=>c11md.setSourceMode(true));assert.equal(await page.evaluate(()=>c11md.visible().mode),'source');
    await page.evaluate(()=>c11md.setSourceMode(false));const back=await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top);assert.ok(Math.abs(top-back)<1,'source round-trip anchor');
  }
  scenario('reload preserves anchor, unchanged node/selection; theme/typeface/scale/outline/source preserve position at all widths');
  // Async diagram replacement above an unchanged lower section holds its position.
  const graph='```mermaid\nflowchart TD\n A --> B\n```\n\n', above='# Async\n\n'+graph+long;
  await settings({scale:1,typeface:'serif'});await load(above,'/synthetic/async.md');await page.evaluate(()=>c11md.scrollToHeading('Section 30'));
  const y=await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top);
  await load(above.replace(' A --> B',' A --> B\n B --> C\n C --> D\n D --> E'),'/synthetic/async.md',2);
  assert.ok(Math.abs(y-await page.locator('#c11md-h-section-30').evaluate(x=>x.getBoundingClientRect().top))<1);
  await page.evaluate(()=>window.unchangedDiagram=document.querySelector('.diagram svg'));
  await load(above.replace(' A --> B',' A --> B\n B --> C\n C --> D\n D --> E')+'\nA tail addition.\n','/synthetic/async.md',3);
  assert.equal(await page.evaluate(()=>unchangedDiagram===document.querySelector('.diagram svg')),true);
  scenario('async Mermaid resize above viewport and unchanged diagram identity across reload');
  await settings({scale:2});assert.equal(await page.evaluate(()=>c11md.visible().pane.effectiveWidth),600);
  await settings({theme:'unknown',typeface:'unknown',scale:8,outlineOpen:'unknown'});
  const fallback=await page.evaluate(()=>c11md.visible());assert.equal(fallback.theme.choice,'system');assert.equal(fallback.typeface.choice,'theme');assert.equal(fallback.font_scale,1);assert.equal(fallback.outline.choice,'auto');
  await settings({theme:'system',osAppearance:'light'});assert.equal(await page.evaluate(()=>c11md.visible().theme.resolved),'light');await settings({osAppearance:'dark'});assert.equal(await page.evaluate(()=>c11md.visible().theme.resolved),'dark');
  scenario('effective-width scale, invalid-setting defaults, system appearance');
  await page.evaluate(async()=>{
    await Promise.all([c11md.load({markdown:'# Concurrent\n\nFirst body.\n',documentPath:'/synthetic/concurrent.md',revision:'first'}),c11md.setSettings({theme:'dark'})]);
  });
  assert.equal(await page.locator('h1').evaluate(x=>x.lastChild.textContent),'Concurrent');
  assert.equal(await page.evaluate(()=>c11md.visible().theme.resolved),'dark');
  await page.evaluate(async()=>{
    await Promise.all([c11md.load({markdown:'# Old\n',documentPath:'/synthetic/concurrent.md',revision:'old'}),c11md.load({markdown:'# New\n',documentPath:'/synthetic/concurrent.md',revision:'new'})]);
  });
  assert.equal(await page.evaluate(()=>c11md.visible().revision),'new');
  assert.equal(await page.evaluate(()=>testMessages.some(x=>x.type==='rendered'&&x.revision==='old')),false);
  scenario('load/settings ordering and superseded load completion');

  const hostile='# Hostile\n\n<script>window.pwned=1</script>\n\n<img src=x onerror="window.pwned=2">\n\n[bad](javascript:alert(1)) [data](data:text/html,bad)\n\n![remote](https://example.invalid/remote.png)\n![data](data:image/svg+xml,bad)\n![escape](../secret.png)\n![encoded](%2e%2e/secret.png)\n![outside](file:///outside/secret.png)\n';
  await load(hostile,'/synthetic/hostile.md');assert.equal(await page.evaluate(()=>window.pwned),undefined);assert.equal(await page.locator('script:not([src]), [onerror], a[href^="javascript:"], img').count(),0);
  // Chromium cannot register WKURLSchemeHandler. Observe the real renderer's
  // output, then remove only those private srcs before its unsupported loader runs.
  // R2 owns delivery of image bytes and symlink/file-type authorization.
  await page.evaluate(()=>{window.assetURLs=[];window.assetObserver=new MutationObserver(records=>{
    for(const record of records)for(const node of record.addedNodes)if(node instanceof Element)for(const img of [ ...(node.matches('img')?[node]:[]),...node.querySelectorAll('img')]) {
      assetURLs.push(img.getAttribute('src'));img.removeAttribute('src');
    }
  });assetObserver.observe(document.getElementById('article'),{childList:true,subtree:true});});
  await load('# Local images\n\n![ok](images/synthetic.png)\n![space](images/synthetic%20image.png)\n![inside](file:///synthetic/images/synthetic.png)\n','/synthetic/images.md');
  assert.equal(await page.locator('img').count(),3);
  assert.deepEqual(await page.evaluate(()=>assetURLs),['c11md-asset://doc/images/synthetic.png','c11md-asset://doc/images/synthetic%20image.png','c11md-asset://doc/images/synthetic.png']);
  await page.evaluate(()=>assetObserver.disconnect());
  scenario('hostile HTML/URLs inert; authorized local image URL policy',{nativeBytes:'R2 WKURLSchemeHandler proof required'});
  await load('# Links\n\n[remote](https://example.invalid/) [local](next.md) [jump](#target)\n\n'+('Text\n\n'.repeat(30))+'## Target\n');
  const url=page.url();await page.getByRole('link',{name:'remote',exact:true}).click();assert.equal(page.url(),url);
  assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='link').kind),'external');
  await page.getByRole('link',{name:'local',exact:true}).click();assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='link').kind),'local');
  await page.locator('a[href="#target"]').click();assert.equal(await page.locator('#back').isVisible(),true);await page.locator('#back').click();
  scenario('link interception/native classification and in-document return pill');
  await load('# Article\n\n## Source\n\n## Target\n\n## Target\n');
  for(const name of ['article','source','target','target-1'])assert.equal(await page.evaluate(name=>c11md.scrollToHeading(name).ok,name),true);
  assert.equal(await page.locator('article#article').count(),1);assert.equal(await page.locator('#source.source').count(),1);
  scenario('heading slugs cannot collide with host DOM IDs; duplicate headings remain addressable');

  await load('# Error\n\n```mermaid\ninvalid diagram text\n```\n');assert.equal(await page.locator('.diagram-err').count(),1);assert.ok((await page.locator('.diagram-err').innerText()).includes('invalid diagram text'));
  scenario('malformed Mermaid produces quiet escaped-source fallback');
  const expected=await page.evaluate(()=>testMessages.filter(x=>x.type==='error'));assert.equal(expected.length,1);assert.equal(expected[0].code,'diagram_failed');
  assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
  scenario('zero console errors and zero network requests');

  if(process.argv.includes('--screenshots')) {
    // Reference runs offline too. Only the fixture page's CDN tags are replaced;
    // content/layout/logic remain the committed binding prototype.
    let prototype=await readFile(path.join(root,'docs/design-prototypes/markdown-viewer/reader/index.html'),'utf8');
    prototype=prototype.replace(/<link rel="stylesheet" href="https:[^"]+">/g,'');
    prototype=prototype.replace('</head>',`<link rel="stylesheet" href="${pathToFileURL(path.join(bundle,'vendor/fonts.css')).href}"></head>`);
    const umd=['markdown-it/dist/browser/markdown-it.umd.min.js','markdown-it-footnote/dist/markdown-it-footnote.min.js','markdown-it-task-lists/dist/markdown-it-task-lists.min.js','@highlightjs/cdn-assets/highlight.min.js','mermaid/dist/mermaid.min.js'];
    // markdown-it 15 ships the classic UMD dist, matching the prototype globals.
    let index=0;prototype=prototype.replace(/<script src="https:[^"]+"><\/script>/g,()=>`<script src="${pathToFileURL(path.join(root,'scripts/markdown-viewer/node_modules',umd[index++])).href}"></script>`);
    const reference=path.join(temporary,'reference.html');await writeFile(reference,prototype);
    const ref=await browser.newPage();
    ref.on('pageerror',e=>console.error('REFERENCE_PAGE_ERROR',e.message));
    ref.on('console',m=>{if(m.type()==='error')console.error('REFERENCE_CONSOLE',m.text());});
    const specimenMD=await readFile(path.join(root,'docs/design-prototypes/markdown-viewer/reader/specimen.md'),'utf8');
    for(const theme of ['light','dark'])for(const width of [560,1200]) {
      await page.setViewportSize({width,height:820});await settings({theme,scale:1,typeface:'serif',outlineOpen:'auto'});await load(specimenMD,'/synthetic/specimen.md');
      const name=`${theme}-${width}`,actual=path.join(output,`${name}-bundle.png`),expected=path.join(output,`${name}-prototype.png`);
      await page.screenshot({path:actual});await ref.setViewportSize({width:width+32,height:1020});
      await ref.goto(pathToFileURL(reference).href+`?w=${width}&os=${theme}&theme=${theme}&doc=specimen`);
      await ref.waitForFunction(()=>document.documentElement.dataset.ready==='1');
      await ref.locator('#scroller').screenshot({path:expected});
      const html=`<!doctype html><meta charset="utf-8"><title>${name}: prototype / bundle</title><style>body{margin:0;display:flex;background:#888;font:14px monospace}figure{margin:0;width:${width}px}figcaption{padding:8px;background:#eee}img{display:block;width:100%}</style><figure><figcaption>Round-4 prototype · ${theme} · ${width}px</figcaption><img src="${path.basename(expected)}"></figure><figure><figcaption>Bundled renderer · ${theme} · ${width}px</figcaption><img src="${path.basename(actual)}"></figure>`;
      const comparison=path.join(output,`${name}-comparison.html`);await writeFile(comparison,html);
      const comparisonPage=await browser.newPage({viewport:{width:width*2,height:860}});await comparisonPage.goto(pathToFileURL(comparison).href);await comparisonPage.screenshot({path:path.join(output,`${name}-comparison.png`)});await comparisonPage.close();
      report.screenshots.push(name+'-comparison.png');
    }
    await ref.close();scenario('prototype/bundle side-by-side screenshots at 560/1200 px in light/dark');
  }
  report.messages=await page.evaluate(()=>({ready:testMessages.filter(x=>x.type==='ready').length,rendered:testMessages.filter(x=>x.type==='rendered').length,state:testMessages.filter(x=>x.type==='state').length}));
  report.result='PASS';await writeFile(path.join(output,'results.json'),JSON.stringify(report,null,2)+'\n');
  console.log(`PASS ${report.scenarios.length} scenarios; evidence: ${output}`);
} finally {await browser.close();await rm(temporary,{recursive:true,force:true});}
