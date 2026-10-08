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
  const policy=await page.locator('meta[http-equiv="Content-Security-Policy"]').getAttribute('content');
  assert.ok(policy.includes("default-src 'none'")&&policy.includes("img-src c11md-asset:")&&policy.includes("connect-src 'none'")&&policy.includes("object-src 'none'"));
  assert.equal(/\bfile:/.test(policy),false,'the app CSP must leave file: access to the native handler');
  scenario('served CSP limits assets to the private image scheme and excludes file access');
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
  assert.equal(await page.locator('.sidenote').evaluate(x=>x.firstElementChild.classList.contains('sn')&&x.firstElementChild.nextSibling?.nodeType===Node.TEXT_NODE),true,'margin-note number is not inline with its text');
  await page.setViewportSize({width:560,height:820});await settings({scale:1});
  assert.equal(await page.locator('.table-wrap.reflow').count(),1);
  await page.locator('.fn-ref a').click();assert.equal(await page.locator('#note').isVisible(),true);
  await page.keyboard.press('Escape');assert.equal(await page.locator('#note').isVisible(),false);
  await page.locator('.copy').click();assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='copy').text),'const answer = 42;\n');
  await page.evaluate(()=>c11md.expandDiagram(1));assert.equal(await page.locator('#diagramOverlay').isVisible(),true);
  await page.locator('[data-zoom="1"]').click();assert.ok(await page.locator('#diagramZoom').evaluate(x=>x.style.transform.includes('1.25')));
  await page.locator('#diagramClose').click();assert.equal(await page.locator('#diagramOverlay').isVisible(),false);
  scenario('callouts, tasks/tree counts, math, highlighting/copy, frontmatter, responsive tables, margin/popover notes, diagram expansion');
  const iconKinds=['NOTE','TIP','IMPORTANT','WARNING','CAUTION'];
  const iconCorpus='# Sanitizer URI paths\n\n[design](c11-x.md)\n\n$\\sqrt{2}$\n\n'+iconKinds.map(kind=>`> [!${kind}]\n> Safe callout.`).join('\n\n');
  await load(iconCorpus,'/synthetic/uri-paths.md');
  assert.equal(await page.locator('a[href="c11-x.md"]').count(),1,'sanitizer removed a relative href');
  await page.locator('a[href="c11-x.md"]').click();
  assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='link').href),'c11-x.md');
  assert.ok(await page.locator('.katex svg path[d]').count()>0,'KaTeX radical path was stripped');
  for(const kind of iconKinds)assert.ok(await page.locator(`.callout-${kind.toLowerCase()} .callout-title svg path[d]`).count()>0,`${kind} icon path was stripped`);
  scenario('relative c11-x link, KaTeX radical path and every callout icon path survive DOMPurify');
  await load('> [!WARNING] Watch out\n> The body stays separate.\n','/synthetic/callout-title.md');
  assert.match(await page.locator('.callout-title').innerText(),/Watch out/);
  assert.equal(await page.locator('blockquote p').innerText(),'The body stays separate.');
  scenario('custom GitHub callout title is rendered in the title slot');
  await load(specimen);
  const infoCorpus='## Info strings\n\n```Mermaid\nflowchart LR\n  A --> B\n```\n\n```mermaid title=sample\nflowchart LR\n  C --> D\n```\n\n- mixed fences\n  ```mermaid title\n  flowchart LR\n    E --> F\n  ```\n  ```js\n  const mixed = 42;\n  ```\n';
  await load(infoCorpus,'/synthetic/info-strings.md');
  assert.equal(await page.locator('.diagram svg').count(),3);assert.equal(await page.locator('.diagram-err').count(),0);
  await page.locator('.code .copy').click();
  assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='copy').text),'const mixed = 42;\n');
  scenario('case-insensitive Mermaid first-word metadata renders diagrams and preserves neighboring code-copy source');
  const diagramURL=page.url(),anchorAllowed=await page.evaluate(()=>{
    const stage=document.querySelector('.diagram-stage'),a=document.createElement('a');a.href='#info-strings';a.textContent='injected link';stage.append(a);
    return a.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
  });
  assert.equal(anchorAllowed,false,'diagram-stage anchor click was not prevented');assert.equal(page.url(),diagramURL);
  scenario('anchor clicks inside diagram stages prevent browser navigation before diagram handling');
  await load(specimen);
  const thematicBreak='---\n\nHorizontal rules stay visible.\n\n---\n\nBody after the rules.\n';
  await load(thematicBreak,'/synthetic/thematic-break.md');
  assert.equal(await page.locator('.frontmatter').count(),0);assert.equal(await page.locator('#article hr').count(),2);
  assert.ok((await page.locator('#article').innerText()).includes('Body after the rules.'));
  await load('---\ntitle: YAML frontmatter\n---\n\nBody after metadata.\n','/synthetic/frontmatter.md');
  assert.equal(await page.locator('.frontmatter').count(),1);assert.ok((await page.locator('#article').innerText()).includes('Body after metadata.'));
  await load('---\ntitle: <img src=x onerror=alert(1)>\nstatus: ready\n---\n\nBody stays safe.\n','/synthetic/frontmatter-grid.md');
  const frontmatter=page.locator('.frontmatter');
  assert.equal(await frontmatter.evaluate(x=>x.tagName),'DL');assert.deepEqual(await frontmatter.locator('dt').allTextContents(),['title','status']);
  assert.deepEqual(await frontmatter.locator('dd').allTextContents(),['<img src=x onerror=alert(1)>','ready']);
  assert.equal(await frontmatter.locator('img,script,[onerror]').count(),0);
  scenario('YAML-like opening frontmatter is removed while leading thematic breaks remain content');
  await load(specimen);
  assert.equal(await page.evaluate(()=>c11md.find('keep the reader’s place').matches),1);
  assert.equal(await page.evaluate(()=>c11md.findNext().current),1);assert.equal(await page.evaluate(()=>c11md.findPrevious().current),1);await page.evaluate(()=>c11md.findClose());
  await load('# Find\n\nalpha **beta** gamma alpha beta gamma\n');
  assert.equal(await page.evaluate(()=>c11md.find('alpha beta').matches),2);assert.equal(await page.evaluate(()=>c11md.findNext().current),2);
  assert.equal(await page.evaluate(()=>c11md.findNext().current),1);assert.equal(await page.evaluate(()=>c11md.findPrevious().current),2);await page.evaluate(()=>c11md.findClose());
  scenario('literal find spans inline formatting, next/previous wrap, close clears marks');
  const findUIDocument='# Find witness\n\nalpha beta alpha beta alpha\n\n'+Array.from({length:24},(_,i)=>`## Find section ${i}\n\nKeep this reader anchor stable while the find popover opens and closes.\n`).join('\n');
  await settings({outlineOpen:false});await load(findUIDocument,'/synthetic/find-ui.md');
  await page.evaluate(()=>c11md.scrollToHeading('Find section 12'));
  const findWitness=()=>page.locator('#c11md-h-find-section-12').evaluate(x=>x.getBoundingClientRect().top);
  const findAnchorBefore=await findWitness();
  await page.evaluate(()=>c11md.openFind());
  assert.equal(await page.locator('#findbar').evaluate(x=>x.classList.contains('open')),true);
  await page.waitForFunction(()=>document.activeElement?.id==='findInput');
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'findInput','opening Find did not focus the page input');
  assert.ok(Math.abs(findAnchorBefore-await findWitness())<1,'opening the empty find popover moved the reading anchor');
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#findbar').evaluate(x=>x.classList.contains('open')),false);
  assert.ok(Math.abs(findAnchorBefore-await findWitness())<1,'closing the empty find popover moved the reading anchor');
  await page.evaluate(()=>c11md.openFind());
  const findInput=page.locator('#findInput');await findInput.fill('alpha');
  await page.waitForFunction(()=>c11md.visible().find?.matches===3);
  assert.equal(await page.locator('#findCount').innerText(),'1 / 3');
  assert.equal(await page.locator('#findTicks i').count(),3);
  await page.locator('#findPrevious').click();assert.equal(await page.locator('#findCount').innerText(),'3 / 3');
  await page.locator('#findNext').click();assert.equal(await page.locator('#findCount').innerText(),'1 / 3');
  await findInput.fill('');
  await page.evaluate(()=>c11md.openFind(false));
  assert.equal(await findInput.inputValue(),'','a find render restored the previous query while the new input was debouncing');
  await page.waitForFunction(()=>c11md.visible().find?.query==='');
  const queriedAnchor=await findWitness();await page.keyboard.press('Escape');
  assert.equal(await page.locator('#findbar').evaluate(x=>x.classList.contains('open')),false,'Escape did not close the find popover');
  assert.equal(await page.locator('mark.hit').count(),0,'Escape left page-owned find marks behind');
  assert.equal(await page.evaluate(()=>c11md.visible().find),null);
  assert.ok(Math.abs(queriedAnchor-await findWitness())<1,'closing the populated find popover moved the reading anchor');
  scenario('page find opens with input focus, reports count, wraps next/previous, clears on Esc, and preserves anchors');
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
  const outlineSample='# Reader\n\n## Tasks\n\n- [x] Complete\n- [ ] Pending\n\n### Child task section\n\n- [ ] Later\n\n## Finish\n\nThe outline filter and jump keep this page open.\n';
  await page.setViewportSize({width:560,height:820});await settings({theme:'light',typeface:'serif',scale:1,outlineOpen:true});
  await load(outlineSample,'/synthetic/outline-controls.md',1);
  const outlineFilter=page.locator('#outlineFilter');
  const localizedFilter='アウトラインを絞り込む';await settings({strings:{outlineFilter:localizedFilter}});
  assert.equal(await outlineFilter.getAttribute('placeholder'),localizedFilter,'outline filter placeholder did not use its localized string');
  assert.equal(await outlineFilter.getAttribute('aria-label'),localizedFilter,'outline filter accessible name did not use its localized string');
  await outlineFilter.fill('Tasks');
  assert.equal(await page.locator('#outlineList a[data-outline-slug="tasks"]').count(),1);
  assert.equal(await page.locator('#outlineList a[data-outline-slug="tasks"] .tc').getAttribute('aria-label'),'1 of 3 tasks complete');
  assert.equal(await page.locator('#outlineList a[data-outline-slug="reader"]').count(),1,'filter did not retain the matching heading parent');
  await page.locator('#outlineList a[data-outline-slug="tasks"]').click();
  await page.waitForFunction(()=>c11md.visible().heading?.slug==='tasks');
  assert.equal(await page.locator('#outlinePanel').evaluate(x=>x.classList.contains('open')),true,'heading jump closed the outline');
  await outlineFilter.fill('task');
  assert.equal(await page.locator('#outlineList a.on').getAttribute('data-outline-slug'),'tasks','filter repaint dropped the active scrollspy mark');
  await outlineFilter.fill('no such heading');assert.equal(await page.locator('#outlineList .empty').innerText(),'No headings match');
  await page.keyboard.press('Escape');
  assert.equal(await outlineFilter.inputValue(),'','Escape did not clear the outline filter first');
  assert.equal(await page.locator('#outlinePanel').evaluate(x=>x.classList.contains('open')),true,'Escape closed the outline before clearing its filter');
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('#outlinePanel').evaluate(x=>x.classList.contains('open')),false,'Escape did not close the outline');
  assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='outlineDismiss')?.type),'outlineDismiss','Escape did not request persistence of the closed choice');
  scenario('page outline filters with ancestor/task context, jumps without closing, and Esc reports the explicit closed choice');

  await page.setViewportSize({width:560,height:820});await settings({theme:'light',typeface:'serif',scale:3,outlineOpen:true});
  await load(outlineSample,'/synthetic/outline-scale-300.md',1);
  const largeOutlineMetrics=await page.locator('.ohead').evaluate(header=>{
    const input=header.querySelector('input'),headerBox=header.getBoundingClientRect(),inputBox=input.getBoundingClientRect();
    return {headerHeight:headerBox.height,inputHeight:inputBox.height,inputFontSize:parseFloat(getComputedStyle(input).fontSize),inputScrollHeight:input.scrollHeight};
  });
  assert.ok(largeOutlineMetrics.headerHeight>=114,`300% outline header clipped its controls: ${largeOutlineMetrics.headerHeight}px`);
  assert.ok(largeOutlineMetrics.inputHeight>=largeOutlineMetrics.inputFontSize*2,`300% outline filter glyphs may clip: ${JSON.stringify(largeOutlineMetrics)}`);
  assert.ok(largeOutlineMetrics.inputHeight>=largeOutlineMetrics.inputScrollHeight,`300% outline filter scroll height exceeds its box: ${JSON.stringify(largeOutlineMetrics)}`);
  scenario('300% outline filter scales its header and input so the glyphs fit');

  await page.setViewportSize({width:1400,height:900});
  await settings({theme:'light',typeface:'serif',scale:1,outlineOpen:true});
  await load(outlineSample,'/synthetic/source-docked-outline.md',1);
  await page.evaluate(()=>c11md.setSourceMode(true));
  assert.equal(await page.evaluate(()=>c11md.visible().outline.docked),true,'source outline fixture did not dock');
  assert.equal(await page.evaluate(()=>c11md.visible().outline.open),true,'source outline fixture did not open');
  const sourceTextBox=await page.locator('#source .sl:first-child .t').boundingBox();
  assert.ok(sourceTextBox,'missing first source text row');
  for(const selector of ['.n','.t']) {
    const box=await page.locator(`#source .sl:first-child ${selector}`).boundingBox();
    assert.ok(box,`missing source row ${selector}`);
    const point={x:box.x+(selector==='.n'?box.width/2:1),y:box.y+box.height/2};
    const result=await page.evaluate(({x,y})=>{
      const hit=document.elementFromPoint(x,y);
      return {sourceRow:!!hit?.closest('#source .sl'),insideOutline:!!hit&&document.querySelector('#outlinePanel').contains(hit)};
    },point);
    assert.equal(result.sourceRow,true,`docked outline covered source ${selector==='.n'?'line number':'text start'}`);
    assert.equal(result.insideOutline,false,`source ${selector} probe hit the outline`);
  }
  await settings({outlineOpen:false});
  const sourceTextAfterClose=await page.locator('#source .sl:first-child .t').boundingBox();
  assert.ok(sourceTextAfterClose&&Math.abs(sourceTextBox.x-sourceTextAfterClose.x)<1,'closing a docked outline shifted source lines');
  scenario('docked outline reserves its gutter over source line numbers and text');

  await load(long,'/synthetic/outline-threshold.md',1);await settings({outlineOpen:'auto'});
  let low=500,high=1600;
  const resizeAndReadDocked=async width=>{
    await page.setViewportSize({width,height:820});
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    return page.evaluate(()=>c11md.visible().outline.docked);
  };
  while(low+1<high) {
    const middle=Math.floor((low+high)/2);
    if(await resizeAndReadDocked(middle))high=middle;else low=middle;
  }
  assert.equal(await resizeAndReadDocked(low),false,'outline docked below its effective-width threshold');
  assert.equal(await resizeAndReadDocked(high),true,'outline did not dock at the first width that fits');
  const stateCountBeforeOutlineJump=await page.evaluate(()=>testMessages.filter(x=>x.type==='state').length);
  await page.evaluate(()=>c11md.scrollToHeading('Section 30'));
  await page.waitForFunction(count=>testMessages.filter(x=>x.type==='state').length>count,stateCountBeforeOutlineJump);
  const outlineTransport=await page.evaluate(()=>({
    keys:Object.keys(c11md.visible().outline).sort(),
    pageHeadings:c11md.outline().length,
    stateMessagesKeepTreePageLocal:testMessages.filter(x=>x.type==='state').every(x=>x.state?.outline&&!Object.hasOwn(x.state.outline,'tree'))
  }));
  assert.deepEqual(outlineTransport.keys,['choice','docked','open']);
  assert.ok(outlineTransport.pageHeadings>0,'the page no longer owns the outline tree');
  assert.equal(outlineTransport.stateMessagesKeepTreePageLocal,true,'a coalesced state message transferred the outline tree');
  scenario('page keeps its heading tree local and bridge state sends only open, docked, and choice');
  const outlineAnchor=()=>page.locator('#c11md-h-section-30').evaluate(x=>{const r=document.createRange();r.selectNodeContents(x.lastChild);const b=r.getBoundingClientRect();return {x:b.left,y:b.top};});
  const assertOutlineAnchor=(before,after,phase)=>{
    assert.ok(Math.abs(before.x-after.x)<1,`${phase} moved the text anchor horizontally ${before.x} -> ${after.x}`);
    assert.ok(Math.abs(before.y-after.y)<1,`${phase} moved the text anchor vertically ${before.y} -> ${after.y}`);
  };
  for(const mode of [{name:'overlay',width:low},{name:'docked',width:high}]) {
    await resizeAndReadDocked(mode.width);await settings({outlineOpen:false});
    const before=await outlineAnchor();
    await settings({outlineOpen:true});const opened=await outlineAnchor();
    assertOutlineAnchor(before,opened,`${mode.name} outline open`);
    assert.equal(await page.evaluate(()=>c11md.visible().outline.docked),mode.name==='docked');
    if(mode.name==='docked')assert.equal(await page.locator('#layout').evaluate(x=>parseFloat(getComputedStyle(x).paddingLeft)>0),true,'closed dock gutter was not reserved');
    await settings({outlineOpen:false});const closed=await outlineAnchor();
    assertOutlineAnchor(before,closed,`${mode.name} outline close`);
  }
  scenario('outline flips between overlay and docked at the exact adjacent-width threshold; open and close preserve the reading anchor in both modes');
  await page.setViewportSize({width:1200,height:820});await settings({outlineOpen:'auto'});

  const evictionMarkdown='# Eviction restore\n\n'+Array.from({length:80},(_,i)=>`Eviction witness ${i}: ${'A visible source line keeps its exact viewport position. '.repeat(2)}`).join('\n\n')+'\n';
  await settings({theme:'light',typeface:'serif',scale:1});await load(evictionMarkdown,'/synthetic/eviction.md',1);
  const captured=await page.evaluate(()=>{
    const block=[...document.querySelector('#article').children].find(x=>x.textContent.startsWith('Eviction witness 40:'));
    const sc=document.querySelector('#scroller'),line=Number(block.dataset.ls),range=document.createRange();range.selectNodeContents(block);
    const origin=range.getClientRects()[0].top-sc.getBoundingClientRect().top+sc.scrollTop;
    sc.scrollTop=origin+8.25;return {line,state:c11md.visible()};
  });
  assert.equal(captured.state.lines.first,captured.line);assert.ok(Math.abs(captured.state.lines.offset-8.25)<=1,`capture offset ${captured.state.lines.offset}`);
  await page.reload();await page.waitForFunction(()=>window.testMessages.some(m=>m.type==='ready'));
  await settings({theme:'light',typeface:'serif',scale:1});await load(evictionMarkdown,'/synthetic/eviction.md',2);
  const restored=await page.evaluate(({line,offset})=>c11md.scrollToLine(line,offset).lines,{line:captured.line,offset:captured.state.lines.offset});
  assert.equal(restored.first,captured.line);assert.ok(Math.abs(restored.offset-captured.state.lines.offset)<=1,`restore offset ${captured.state.lines.offset} -> ${restored.offset}`);
  scenario('eviction restore after fresh page reload preserves first visible source line and signed CSS-pixel offset');
  const codeLines=Array.from({length:80},(_,i)=>`const line${String(i).padStart(2,'0')} = ${i};`).join('\n');
  const fenceDocument=language=>`# Fence line mapping\n\n${language?`\`\`\`${language}`:'```'}\n${codeLines}\n\`\`\`\n`;
  const parkFenceLine=async(needle,offset=8.25)=>page.evaluate(({needle,offset})=>{
    const sc=document.querySelector('#scroller'),code=[...document.querySelectorAll('.code pre code')].find(x=>x.textContent.includes(needle));
    if(!code)throw new Error(`missing code line ${needle}`);
    const walker=document.createTreeWalker(code,NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())) {
      const start=node.textContent.indexOf(needle);if(start<0)continue;
      const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+needle.length);
      sc.scrollTop+=range.getBoundingClientRect().top-sc.getBoundingClientRect().top+offset;
      return {top:range.getBoundingClientRect().top-sc.getBoundingClientRect().top,scrollTop:sc.scrollTop};
    }
    throw new Error(`missing text node for ${needle}`);
  },{needle,offset});
  const expectedFenceLine=44,sourceToggleResults=[];
  for(const language of ['javascript','']) {
    await load(fenceDocument(language),'/synthetic/fence-lines.md');await parkFenceLine('line40');
    await page.evaluate(()=>c11md.setSourceMode(true));
    sourceToggleResults.push({language:language||'plain',lines:await page.evaluate(()=>c11md.visible().lines)});
    await page.evaluate(()=>c11md.setSourceMode(false));
  }
  const sourceTogglePass=sourceToggleResults.every(x=>x.lines.first===expectedFenceLine&&Math.abs(x.lines.offset-8.25)<=1);
  await load(fenceDocument('javascript'),'/synthetic/fence-offset-roundtrip.md');await parkFenceLine('line40');
  await page.evaluate(()=>c11md.setSourceMode(true));
  await page.evaluate(()=>{document.querySelector('#srcScroller').scrollTop+=4.5;});
  const movedSourceOffset=await page.evaluate(()=>c11md.visible().lines);
  await page.evaluate(()=>c11md.setSourceMode(false));
  const movedReadOffset=await page.evaluate(()=>{
    const sc=document.querySelector('#scroller'),code=[...document.querySelectorAll('.code pre code')].find(x=>x.textContent.includes('line40'));
    const walker=document.createTreeWalker(code,NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())) {const start=node.textContent.indexOf('line40');if(start<0)continue;
      const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+6);
      return {lines:c11md.visible().lines,textTop:range.getBoundingClientRect().top-sc.getBoundingClientRect().top};}
    throw new Error('line40 not found after returning to read mode');
  });
  const sourceOffsetRoundtripPass=movedSourceOffset.first===expectedFenceLine&&Math.abs(movedSourceOffset.offset-12.75)<=1&&
    movedReadOffset.lines.first===expectedFenceLine&&Math.abs(movedReadOffset.lines.offset-movedSourceOffset.offset)<=1&&
    Math.abs(movedReadOffset.textTop+movedSourceOffset.offset)<=1;
  await load(fenceDocument('javascript'),'/synthetic/scroll-to-fence-line.md');
  const interiorLine=await page.evaluate(line=>{
    const result=c11md.scrollToLine(line),sc=document.querySelector('#scroller'),code=[...document.querySelectorAll('.code pre code')].find(x=>x.textContent.includes('line40'));
    const walker=document.createTreeWalker(code,NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())) {const start=node.textContent.indexOf('line40');if(start<0)continue;
      const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+6);
      return {line,result:result.lines,textTop:range.getBoundingClientRect().top-sc.getBoundingClientRect().top};}
    throw new Error('line40 not found');
  },expectedFenceLine);
  const scrollToLinePass=interiorLine.result.first===expectedFenceLine&&Math.abs(interiorLine.textTop)<1;
  await load(fenceDocument('javascript'),'/synthetic/fence-offset.md');await parkFenceLine('line40');
  const fenceCapture=await page.evaluate(()=>c11md.visible().lines);
  await page.reload();await page.waitForFunction(()=>window.testMessages.some(m=>m.type==='ready'));
  await settings({theme:'light',typeface:'serif',scale:1});await load(fenceDocument('javascript'),'/synthetic/fence-offset.md',2);
  const fenceRestore=await page.evaluate(({line,offset})=>{
    const result=c11md.scrollToLine(line,offset),sc=document.querySelector('#scroller'),code=[...document.querySelectorAll('.code pre code')].find(x=>x.textContent.includes('line40'));
    const walker=document.createTreeWalker(code,NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())) {const start=node.textContent.indexOf('line40');if(start<0)continue;
      const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+6);
      return {result:result.lines,textTop:range.getBoundingClientRect().top-sc.getBoundingClientRect().top};}
    throw new Error('line40 not found');
  },{line:fenceCapture.first,offset:fenceCapture.offset});
  const fenceOffsetPass=fenceCapture.first===expectedFenceLine&&fenceRestore.result.first===expectedFenceLine&&Math.abs(fenceRestore.result.offset-fenceCapture.offset)<=1&&Math.abs(fenceRestore.textTop+fenceCapture.offset)<=1;
  if(!sourceTogglePass||!sourceOffsetRoundtripPass||!scrollToLinePass||!fenceOffsetPass)console.error('R2_LINE_MAPPING_PROBES',JSON.stringify({sourceToggle:{pass:sourceTogglePass,results:sourceToggleResults},sourceOffsetRoundtrip:{pass:sourceOffsetRoundtripPass,source:movedSourceOffset,read:movedReadOffset},scrollToLine:{pass:scrollToLinePass,result:interiorLine},eviction:{pass:fenceOffsetPass,captured:fenceCapture,restored:fenceRestore}}));
  assert.ok(sourceTogglePass,'source toggle did not preserve the highlighted and plain fence line/offset');
  assert.ok(sourceOffsetRoundtripPass,'source-to-read toggle did not preserve the changed offset within the same fence line');
  assert.ok(scrollToLinePass,'scrollToLine did not put the requested code line at the viewport top');
  assert.ok(fenceOffsetPass,'fresh reload did not restore the same interior fence line and signed offset within one pixel');
  scenario('source toggle preserves the interior line and offset in highlighted and plain fences');
  scenario('source-to-read toggle maps a changed offset within the same fence line');
  scenario('scrollToLine targets an interior highlighted-fence line in read mode');
  scenario('fresh reload restores the same interior fence line and signed offset within one pixel');
  const readLineTop=needle=>page.evaluate(needle=>{
    const walker=document.createTreeWalker(document.querySelector('#article'),NodeFilter.SHOW_TEXT);let node;
    while((node=walker.nextNode())) {const start=node.textContent.indexOf(needle);if(start<0)continue;
      const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+needle.length);
      return range.getBoundingClientRect().top-document.querySelector('#scroller').getBoundingClientRect().top;}
    throw new Error(`missing rendered line ${needle}`);
  },needle);
  const paragraphLines=Array.from({length:80},(_,i)=>`Paragraph line${String(i).padStart(2,'0')} keeps its source line marker.`).join('\n');
  await load(`# Paragraph line mapping\n\n${paragraphLines}\n`,'/synthetic/paragraph-lines.md');
  const paragraphResult=await page.evaluate(()=>c11md.scrollToLine(43).lines),paragraphTop=await readLineTop('Paragraph line40');
  assert.equal(paragraphResult.first,43);assert.ok(Math.abs(paragraphTop)<1,'paragraph source line was not placed at the viewport top');
  const listLines=Array.from({length:80},(_,i)=>`- List line${String(i).padStart(2,'0')} keeps its source line marker.`).join('\n');
  await load(`# List line mapping\n\n${listLines}\n`,'/synthetic/list-lines.md');
  const listResult=await page.evaluate(()=>c11md.scrollToLine(43).lines),listTop=await readLineTop('List line40');
  assert.equal(listResult.first,43);assert.ok(Math.abs(listTop)<1,'list source line was not placed at the viewport top');
  scenario('source line mapping also targets interior paragraph and list lines');
  const diagramAbove='```mermaid\nflowchart TD\n  A[Input] --> B[Output]\n```\n\n'+long;
  await settings({theme:'system',osAppearance:'dark',typeface:'serif',scale:1});await load(diagramAbove,'/synthetic/diagram-theme.md',1);
  await page.evaluate(()=>c11md.scrollToHeading('Section 30'));
  const diagramWitness=()=>page.locator('#c11md-h-section-30').evaluate(x=>{const r=document.createRange();r.selectNodeContents(x.lastChild);return r.getBoundingClientRect().top;});
  const themeStart=await diagramWitness();await settings({theme:'light'});
  assert.ok(Math.abs(themeStart-await diagramWitness())<1,'theme change moved reader below diagram');
  await settings({theme:'system',osAppearance:'light'});const appearanceStart=await diagramWitness();
  await settings({osAppearance:'dark'});
  assert.ok(Math.abs(appearanceStart-await diagramWitness())<1,'OS appearance flip moved reader below diagram');
  scenario('diagram theme changes and OS appearance flips preserve reader position');
  const literalDiagrams=[
    'flowchart LR\n  A["literal <img src=x onerror=alert(1)> label"] --> B',
    'flowchart LR\n  A["literal <image> label"] --> B',
    'flowchart LR\n  A["literal url(https://example.invalid/) and @import label"] --> B',
    'flowchart LR\n  A["first line\n---\nlast line"] --> B',
  ];
  await load(literalDiagrams.map(x=>['```mermaid',x,'```'].join('\n')).join('\n\n'),'/synthetic/diagram-literals.md');
  assert.equal(await page.locator('.diagram svg').count(),literalDiagrams.length);
  assert.equal(await page.locator('.diagram-err').count(),0,'ordinary label text was refused as a directive');
  scenario('Mermaid labels may document HTML, CSS and thematic-rule text without activating it');
  const hostileMermaid=[
    '%%{init: {"securityLevel":"loose","htmlLabels":true}}%%\nflowchart LR\n  A --> B',
    '---\nconfig:\n  securityLevel: loose\n---\nflowchart LR\n  A --> B',
    'flowchart LR\n  A[Alpha] --> B[Beta]\n  click A href "javascript:alert(1)" "unsafe"',
    'sequenceDiagram\n  participant Alice\n  participant Bob\n  link Alice: "javascript:alert(1)" "unsafe"\n  Alice->>Bob: hello',
    'classDiagram\n  class Alpha\n  link Alpha "javascript:alert(1)" "unsafe"',
    'flowchart LR\n  A["<img src=x onerror=alert(1)>"] --> B',
    'flowchart LR\n  A[alpha] --> B[beta]\n  style A fill:url(https://example.invalid/evil)',
  ];
  const hostileMarkdown=hostileMermaid.map(x=>['```mermaid',x,'```'].join('\n')).join('\n\n');
  await load(hostileMarkdown,'/synthetic/hostile-mermaid.md');
  assert.equal(await page.locator('.diagram').count(),hostileMermaid.length);
  const directiveFallbacks=await page.locator('.diagram-err pre').allTextContents();
  assert.equal(directiveFallbacks.length>=2,true,'Mermaid init and frontmatter config directives were not refused');
  assert.ok(directiveFallbacks.some(x=>x.includes('%%{init:')));assert.ok(directiveFallbacks.some(x=>x.includes('securityLevel')));
  assert.equal(await page.evaluate(()=>testMessages.filter(x=>x.type==='error'&&x.message.includes('Unsupported diagram directive')).length),2);
  assert.equal(await page.evaluate(()=>mermaid.mermaidAPI.getConfig().securityLevel),'strict');
  assert.equal(await page.evaluate(()=>mermaid.mermaidAPI.getConfig().htmlLabels),false);
  const activeDiagramFindings=await page.evaluate(()=>{
    const findings=[];
    for(const stage of document.querySelectorAll('.diagram-stage'))for(const node of stage.querySelectorAll('*')) {
      if(['IMG','SCRIPT','FOREIGNOBJECT','A'].includes(node.tagName.toUpperCase()))findings.push({tag:node.tagName});
      for(const attr of node.attributes)if(!/^xmlns(?::|$)/i.test(attr.name)&&(/^on|^(?:xlink:)?href$|^src$/i.test(attr.name)||/(?:javascript:|data:|file:|https?:\/\/|url\s*\(\s*['"]?(?:https?:|\/\/|javascript:|data:|file:))/i.test(attr.value)))findings.push({tag:node.tagName,attr:attr.name,value:attr.value});
    }
    for(const style of document.querySelectorAll('.diagram-stage svg style'))if(/https?:\/\//i.test(style.textContent))findings.push({tag:'style',text:style.textContent});
    return findings;
  });
  assert.deepEqual(activeDiagramFindings,[],'hostile Mermaid output contains an active element or external reference');
  assert.equal(await page.evaluate(()=>window.__owned),undefined);
  scenario('hostile Mermaid directives, links, labels and styles remain inert under strict mode');
  const unsafeSvg='<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><img src="https://example.invalid/x" onerror="window.__owned=1"></foreignObject><image href="https://example.invalid/x"/><a href="javascript:window.__owned=2"><text>bad</text></a><script>window.__owned=3</script><path d="M0 0" onload="window.__owned=4"/></svg>';
  await page.evaluate(svg=>{window.originalMermaidRender=mermaid.render;mermaid.render=async()=>({svg});},unsafeSvg);
  await load('```mermaid\nflowchart LR\n  A --> B\n```\n','/synthetic/svg-sanitizer.md');
  await page.evaluate(()=>{mermaid.render=window.originalMermaidRender;delete window.originalMermaidRender;});
  assert.equal(await page.locator('.diagram-stage svg').count(),1);
  assert.equal(await page.locator('.diagram-stage foreignObject,.diagram-stage image,.diagram-stage a,.diagram-stage script,.diagram-stage img,.diagram-stage [onerror],.diagram-stage [onload],.diagram-stage [href]').count(),0);
  assert.equal(await page.evaluate(()=>window.__owned),undefined);
  scenario('SVG sanitizer removes injected active elements, handlers, and external references');
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
  await load('# Host-bearing local URLs\n\n[file host](file://host/share/x.md) [protocol host](//host/share/x.md)\n');
  for(const name of ['file host','protocol host']) {
    await page.getByRole('link',{name,exact:true}).click();
    const link=await page.evaluate(()=>testMessages.findLast(x=>x.type==='link'));
    assert.equal(link.kind,'blocked',`${name} was treated as a local file`);assert.equal(link.resolvedURL,null);
  }
  scenario('file and protocol-relative links with a host are blocked');
  await load('[empty]()\n','/synthetic/empty-link.md');
  const emptyLink=page.getByRole('link',{name:'empty',exact:true});
  if(await emptyLink.count())await emptyLink.click();
  const emptyMessages=await page.evaluate(()=>testMessages.filter(x=>x.type==='link'));
  assert.ok(emptyMessages.length===0||emptyMessages.at(-1).kind==='blocked'&&emptyMessages.at(-1).resolvedURL===null,'empty link targeted the current document');
  scenario('empty Markdown links do not target the current document');
  await load('# Links\n\n[remote](https://example.invalid/) [local](next.md) [jump](#target)\n\n'+('Text\n\n'.repeat(30))+'## Target\n');
  const url=page.url();await page.getByRole('link',{name:'remote',exact:true}).click();assert.equal(page.url(),url);
  assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='link').kind),'external');
  await page.getByRole('link',{name:'local',exact:true}).click();assert.equal(await page.evaluate(()=>testMessages.findLast(x=>x.type==='link').kind),'local');
  await page.locator('#article a[href="#target"]').click();assert.equal(await page.locator('#back').isVisible(),true);await page.locator('#back').click();
  scenario('link interception/native classification and in-document return pill');
  await load('# Article\n\n## Source\n\n## Target\n\n## Target\n');
  for(const name of ['article','source','target','target-1'])assert.equal(await page.evaluate(name=>c11md.scrollToHeading(name).ok,name),true);
  assert.equal(await page.locator('article#article').count(),1);assert.equal(await page.locator('#source.source').count(),1);
  scenario('heading slugs cannot collide with host DOM IDs; duplicate headings remain addressable');

  await load('# Error\n\n```mermaid\ninvalid diagram text\n```\n');assert.equal(await page.locator('.diagram-err').count(),1);assert.ok((await page.locator('.diagram-err').innerText()).includes('invalid diagram text'));
  scenario('malformed Mermaid produces quiet escaped-source fallback');
  const expected=await page.evaluate(()=>testMessages.filter(x=>x.type==='error'));
  assert.ok(expected.length>=3);assert.equal(expected.filter(x=>x.code!=='diagram_failed').length,0);
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
