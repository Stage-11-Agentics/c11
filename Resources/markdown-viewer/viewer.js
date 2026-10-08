/* c11 markdown engine. Host API and security boundaries: BRIDGE.md. */
(() => {
'use strict';
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
const surface = $('#surface'), scroller = $('#scroller'), srcScroller = $('#srcScroller');
const article = $('#article'), col = $('#col'), layout = $('#layout'), source = $('#source');
const defaults = {copy:'copy', copied:'copied', copyLink:'copy link to this section', expand:'expand ⤢', close:'close', diagram:'diagram', diagramError:'Diagram could not be rendered', imageBlocked:'Image unavailable', notes:'notes', back:'back to', source:'source', frontmatter:'frontmatter'};
const S = {markdown:'', file:'', baseURL:'', revision:null, mode:'read', scale:1,
  theme:'system', typeface:'theme', outlineChoice:'auto', os:null, resolved:'dark', face:'serif',
  heads:[], tree:[], blocks:[], generation:0, renderQueue:Promise.resolve(),
  find:{query:'', hits:[], index:-1}, strings:{...defaults}, words:0, lines:1, diagram:null};
function post(message) { window.webkit?.messageHandlers?.c11md?.postMessage(message); }
function error(code, e) { post({type:'error', code, message:String(e?.message || e).slice(0,400), revision:S.revision}); }
const plain = t => (t.children || []).map(c => ['text','code_inline','image'].includes(c.type) ? c.content : '').join('').trim();
const slugify = s => s.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').replace(/\s/g,'-');
const {MarkdownIt, footnote, tasks, anchor} = window.C11Markdown;
const md = new MarkdownIt({html:false, linkify:true, typographer:true})
  .use(footnote).use(tasks,{enabled:false,label:true}).use(anchor,{slugify,tabIndex:false});
md.disable(['replacements']);
md.linkify.set({fuzzyLink:false, fuzzyEmail:false});
const originalValidateLink=md.validateLink;
md.validateLink=href=>/^file:/i.test(href)||originalValidateLink(href);

// Local first-party plugin, ported from the binding round-4 reader.
function callouts(parser) {
  parser.core.ruler.after('inline','c11_callouts',state => {
    const T = state.tokens;
    for (let i=0; i<T.length-2; i++) {
      if(T[i].type!=='blockquote_open'||T[i+1].type!=='paragraph_open'||T[i+2].type!=='inline') continue;
      const t=T[i+2], m=t.content.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*/i);
      if(!m) continue;
      const kind=m[1].toLowerCase(), remainder=t.content.slice(m[0].length), title=remainder.split('\n',1)[0].trim()||kind;
      T[i].attrJoin('class','callout callout-'+kind); T[i].meta={callout:kind,title};
      while(t.children.length&&!['softbreak','hardbreak'].includes(t.children[0].type))t.children.shift();
      if(['softbreak','hardbreak'].includes(t.children[0]?.type))t.children.shift();
      if(!t.children.length) {T[i+1].hidden=true;T[i+3].hidden=true;}
    }
  });
}
md.use(callouts);

// Math is parsed as tokens, never by walking arbitrary HTML after insertion.
md.inline.ruler.before('escape','c11_math', (state,silent) => {
  const start=state.pos;
  if(state.src[start]!=='$'||state.src[start+1]==='$'||/\s/.test(state.src[start+1]||' ')) return false;
  let end=start+1;
  while((end=state.src.indexOf('$',end))>=0) { if(state.src[end-1]!=='\\') break;end++; }
  if(end<0||/\s/.test(state.src[end-1])||/\d/.test(state.src[end+1]||'')) return false;
  if(!silent) {const t=state.push('math_inline','math',0);t.content=state.src.slice(start+1,end);}
  state.pos=end+1;return true;
});
md.block.ruler.before('fence','c11_math_block',(state,start,end,silent) => {
  const first=state.src.slice(state.bMarks[start]+state.tShift[start],state.eMarks[start]);
  if(!first.startsWith('$$')) return false;
  let last=start, text=first.slice(2), closed=text.endsWith('$$');
  if(closed) text=text.slice(0,-2);
  else for(last=start+1;last<end;last++) {
    const line=state.src.slice(state.bMarks[last]+state.tShift[last],state.eMarks[last]);
    if(line.trim().endsWith('$$')) {text+='\n'+line.slice(0,line.lastIndexOf('$$'));closed=true;break;}
    text+='\n'+line;
  }
  if(!closed) return false;
  if(!silent) {const t=state.push('math_block','math',0);t.block=true;t.content=text;t.map=[start,last+1];state.line=last+1;}
  return true;
});
const math = (t, displayMode) => katex.renderToString(t.content,{displayMode,throwOnError:false,trust:false,strict:'ignore',maxSize:20,maxExpand:1000});
md.renderer.rules.math_inline = (T,i) => math(T[i],false);
md.renderer.rules.math_block = (T,i) => `<div class="math-block">${math(T[i],true)}</div>`;
const ICONS = {
  note: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6.25"/><path d="M8 7.2v4M8 4.8v.1" stroke-linecap="round"/></svg>',
  tip: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M5.6 10.2C4.4 9.3 3.8 8.1 3.8 6.8a4.2 4.2 0 1 1 8.4 0c0 1.3-.6 2.5-1.8 3.4v1.3H5.6z"/><path d="M6.2 14h3.6" stroke-linecap="round"/></svg>',
  important: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M2.5 3.5h11v7.5H8l-3 2.5V11H2.5z"/><path d="M8 5.4v2.8M8 9.6v.1" stroke-linecap="round"/></svg>',
  warning: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M8 2.2 14.2 13H1.8z"/><path d="M8 6.4v3M8 11.2v.1" stroke-linecap="round"/></svg>',
  caution: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M5.4 1.9h5.2l3.5 3.5v5.2l-3.5 3.5H5.4l-3.5-3.5V5.4z"/><path d="M8 5v3.6M8 10.8v.1" stroke-linecap="round"/></svg>',
};
const R=md.renderer.rules;
const isMermaidInfo=info=>String(info||'').trim().split(/\s+/,1)[0].toLowerCase()==='mermaid';
R.blockquote_open=(T,i,o,e,self) => self.renderToken(T,i,o)+(T[i].meta?.callout ? `<div class="callout-title">${ICONS[T[i].meta.callout]}${esc(T[i].meta.title||T[i].meta.callout)}</div>`:'');
R.fence=(T,i) => {
  const t=T[i], lang=t.info.trim().split(/\s+/)[0].toLowerCase();
  if(isMermaidInfo(t.info)) return `<figure class="diagram"><div class="diagram-stage"></div><figcaption><span class="cap"></span><button class="expand">${esc(S.strings.expand)}</button></figcaption></figure>`;
  let html=esc(t.content);
  if(lang && hljs.getLanguage(lang)) {try {html=hljs.highlight(t.content,{language:lang,ignoreIllegals:true}).value;}catch{/* escaped fallback */}}
  return `<div class="code"><div class="code-head"><span>${esc(lang||'text')}</span><button class="copy">${esc(S.strings.copy)}</button></div><pre><code class="hljs">${html.replace(/\n$/,'')}</code></pre></div>`;
};
R.code_block=R.fence;
R.image=(T,i) => {
  const t=T[i], url=assetURL(t.attrGet('src')||''), alt=t.content;
  return url ? `<img src="${esc(url)}" alt="${esc(alt)}">` : `<span class="image-blocked" role="img" aria-label="${esc(alt||S.strings.imageBlocked)}">${esc(S.strings.imageBlocked)}${alt ? ': '+esc(alt):''}</span>`;
};
R.footnote_ref=(T,i) => {const n=T[i].meta.id+1, sub=T[i].meta.subId;return `<sup class="fn-ref"><a href="#fn-${n}" id="fnref-${n}${sub?'-'+sub:''}" data-fn="${n}">${n}</a></sup>`;};
R.footnote_block_open=()=>`<section class="footnotes"><div class="fn-title">${esc(S.strings.notes)}</div><ol>`;
R.footnote_block_close=()=>'</ol></section>';
R.footnote_open=(T,i)=>`<li id="fn-${T[i].meta.id+1}" data-fn="${T[i].meta.id+1}">`;
R.footnote_anchor=(T,i)=>` <a class="fn-back" href="#fnref-${T[i].meta.id+1}">↩</a>`;

function assetURL(raw) {
  try {
    const decoded=decodeURIComponent(raw);
    if(/[\u0000-\u001f\\]/.test(decoded)||decoded.split(/[/?#]/).includes('..')) return null;
    if(/^\/\//.test(decoded)||/^[a-z][a-z\d+.-]*:/i.test(decoded)&&!/^file:/i.test(decoded)) return null;
    const base = S.baseURL || new URL(S.file,'file:///').href;
    const doc = new URL(base), dir=new URL('.',doc);
    if(dir.protocol!=='file:') return null;
    const url=new URL(raw,dir);
    if(url.protocol!=='file:'||url.host!==dir.host||!url.pathname.startsWith(dir.pathname)) return null;
    const path=decodeURIComponent(url.pathname.slice(dir.pathname.length));
    if(!path||path.split('/').some(x=>x==='..'||x==='.'||!x)||/[\u0000-\u001f\\]/.test(path)) return null;
    return 'c11md-asset://doc/'+path.split('/').map(encodeURIComponent).join('/');
  } catch {return null;}
}
function linkInfo(href) {
  if(!href) return {kind:'blocked',resolvedURL:null};
  if(href.startsWith('#')) return {kind:'anchor',resolvedURL:href};
  try {
    if(/[\u0000-\u0020]/.test(href)) return {kind:'blocked',resolvedURL:null};
    const url=new URL(href,S.baseURL||new URL(S.file,'file:///').href);
    if(url.protocol==='file:'&&url.host)return {kind:'blocked',resolvedURL:null};
    return {kind: url.protocol==='file:' ? 'local' : ['http:','https:','mailto:'].includes(url.protocol) ? 'external':'blocked', resolvedURL:['file:','http:','https:','mailto:'].includes(url.protocol)?url.href:null};
  } catch {return {kind:'blocked',resolvedURL:null};}
}
function prep(markdown) {
  const m=markdown.match(/^---\n([\s\S]*?)\n(?:---|\.\.\.)(?:\n|$)/);
  const first=m?.[1].split('\n').find(line=>line.trim()&&!line.trim().startsWith('#'))?.trim();
  const yamlLike=first&&/^[A-Za-z_][\w.-]*\s*:\s*.*$/.test(first);
  return m&&yamlLike ? {body:'\n'.repeat(m[0].split('\n').length-1)+markdown.slice(m[0].length),fm:m} : {body:markdown,fm:null};
}
function renderFrontmatter(content) {
  const dl=document.createElement('dl');dl.className='frontmatter';let last=null;
  content.split('\n').forEach((line,index)=>{
    const trimmed=line.trim();if(!trimmed||trimmed.startsWith('#'))return;
    const match=/^([A-Za-z_][\w.-]*)\s*:\s*(.*)$/.exec(trimmed);
    if(!match){if(last)last.textContent+='\n'+trimmed;return;}
    const dt=document.createElement('dt'),dd=document.createElement('dd'),sourceLine=String(index+2);
    dt.textContent=match[1];dd.textContent=match[2];dt.dataset.sourceLine=sourceLine;dd.dataset.sourceLine=sourceLine;
    dl.append(dt,dd);last=dd;
  });
  return dl;
}
function signature(tokens) {
  return JSON.stringify(tokens, (k,v)=>['map','level','block'].includes(k)?undefined:v);
}
function groups(tokens) {
  const out=[];
  for(let i=0;i<tokens.length;) {
    const start=i; let depth=tokens[i].nesting;
    i++;
    if(depth>0) while(i<tokens.length && depth>0) {depth+=tokens[i].nesting;i++;}
    out.push(tokens.slice(start,i));
  }
  return out;
}
function sanitize(html) {
  return DOMPurify.sanitize(html, {ADD_ATTR:['data-fn','data-label'],ADD_URI_SAFE_ATTR:['data-fn'],
    FORBID_TAGS:['script','style','iframe','object','embed','form','video','audio','source'],
    ALLOWED_URI_REGEXP:/^(?:(?:https?|mailto|file|c11md-asset):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i});
}
const lineMapSkip='svg,button,.code-head,figcaption,.katex-mathml,.callout-title,.fn-back';
function lineTree(root) {
  return document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT|NodeFilter.SHOW_TEXT,{acceptNode:n=>{
    if(n.nodeType===Node.ELEMENT_NODE) {
      if(n.matches(lineMapSkip))return NodeFilter.FILTER_REJECT;
      return n.tagName==='BR'?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_SKIP;
    }
    return NodeFilter.FILTER_ACCEPT;
  }});
}
function textLinePoints(root,skipLeadingWhitespace=false) {
  if(!root)return [];
  const points=[],walker=lineTree(root);let n,offset=0,lineStarted=false,nonWhitespace=false,contentSeen=false;
  while((n=walker.nextNode())) {
    if(n.nodeType===Node.ELEMENT_NODE) {
      if(!lineStarted&&(!skipLeadingWhitespace||contentSeen))points.push(offset);
      lineStarted=false;nonWhitespace=false;offset++;continue;
    }
    for(let i=0;i<n.data.length;i++) {
      const ch=n.data[i];
      if(ch==='\n') {if(!lineStarted&&(!skipLeadingWhitespace||contentSeen))points.push(offset);lineStarted=false;nonWhitespace=false;offset++;continue;}
      if(!lineStarted) {
        if(skipLeadingWhitespace&&!contentSeen&&/\s/.test(ch)){offset++;continue;}
        points.push(offset);lineStarted=true;
      }
      if(!nonWhitespace&&!/\s/.test(ch)){points[points.length-1]=offset;nonWhitespace=true;contentSeen=true;}
      offset++;
    }
  }
  return points;
}
function textOffsetAt(root,target,localOffset) {
  if(!root||!target)return null;
  const walker=lineTree(root);let n,offset=0;
  while((n=walker.nextNode())) {
    if(n===target)return offset+localOffset;
    offset+=n.nodeType===Node.ELEMENT_NODE?1:n.data.length;
  }
  return null;
}
function lineIndexAt(points,offset) {
  if(!points?.length||offset===null)return null;
  let low=0,high=points.length;
  while(low<high) {const mid=(low+high)>>1;if(points[mid]<=offset)low=mid+1;else high=mid;}
  return Math.max(0,low-1);
}
function pointAtTextOffset(root,targetOffset) {
  const walker=lineTree(root);let n,offset=0;
  while((n=walker.nextNode())) {
    if(n.nodeType===Node.ELEMENT_NODE) {if(targetOffset<=offset)return {node:n.parentNode,offset:[...n.parentNode.childNodes].indexOf(n)};offset++;continue;}
    if(targetOffset<offset+n.data.length)return {node:n,offset:targetOffset-offset};
    offset+=n.data.length;
  }
  return null;
}
function pointTop(root,targetOffset,sc) {
  const point=pointAtTextOffset(root,targetOffset);if(!point)return null;
  const range=document.createRange();
  if(point.node.nodeType===Node.TEXT_NODE) {
    const end=Math.min(point.offset+1,point.node.data.length);
    if(end>point.offset)range.setStart(point.node,point.offset),range.setEnd(point.node,end);
    else range.setStart(point.node,point.offset),range.collapse(true);
  } else range.setStart(point.node,point.offset),range.collapse(true);
  const rect=range.getBoundingClientRect();if(!rect.height)return null;
  const box=sc.getBoundingClientRect();return rect.top-box.top+sc.scrollTop;
}
function lineForText(block,text) {
  if(!text?.node)return null;
  if(block.matches('.frontmatter')) {
    const cell=text.node.parentElement?.closest('[data-source-line]');return cell?+cell.dataset.sourceLine:null;
  }
  const code=text.node.parentElement?.closest('.code');
  if(code&&block.contains(code)) {
    const root=$('pre code',code),offset=textOffsetAt(root,text.node,text.offset),index=lineIndexAt(code._linePoints,offset);
    return index===null?null:(code._sourceLineStart||+block.dataset.ls+1)+index;
  }
  const offset=textOffsetAt(block,text.node,text.offset),index=lineIndexAt(block._linePoints,offset);
  return index===null?null:(block._lineBase||+block.dataset.ls)+index;
}
function lineAtOrBefore(root,points,base,scrollY,sc) {
  if(!points?.length)return null;
  let low=0,high=points.length;
  while(low<high) {
    const mid=(low+high)>>1,top=pointTop(root,points[mid],sc);
    if(top!==null&&top<=scrollY+.25)low=mid+1;else high=mid;
  }
  return low?base+low-1:null;
}
function lineAtY(block,scrollY,sc) {
  if(block.matches('.frontmatter')) {
    let found=null;for(const row of block._frontmatterRows||[])if(topIn(row,sc)<=scrollY+.25)found=+row.dataset.sourceLine;else break;
    return found??+block.dataset.ls;
  }
  const codes=[...(block.matches('.code')?[block]:[]),...$$('.code',block)];
  const code=codes.find(x=>topIn(x,sc)<=scrollY+.25&&topIn(x,sc)+(x.offsetHeight||1)>scrollY);
  if(code) {
    const line=lineAtOrBefore($('pre code',code),code._linePoints,code._sourceLineStart,scrollY,sc);
    if(line!==null)return line;
    return +block.dataset.ls;
  }
  return lineAtOrBefore(block,block._linePoints,block._lineBase||+block.dataset.ls,scrollY,sc)??+block.dataset.ls;
}
function prepareBlock(node,tokens) {
  const headingTokens=tokens.filter(t=>t.type==='heading_open');
  const headings=$$('h1,h2,h3,h4,h5,h6',node);if(/^H[1-6]$/.test(node.tagName))headings.unshift(node);
  headings.forEach((h,i)=>{
    const slug=headingTokens[i]?.attrGet('id');if(!slug)return;
    h.dataset.headingSlug=slug;h.id='c11md-h-'+slug;
    const a=document.createElement('button');a.className='h-anchor';a.textContent='#';a.title=S.strings.copyLink;a.dataset.slug=slug;h.prepend(a);
  });
  $$('input[type="checkbox"]',node).forEach(x=>{x.disabled=true;if(x.checked)x.closest('li')?.classList.add('done-item');});
  const table=node.matches('table')?node:node.querySelector('table');
  if(table) {
    const wrap=document.createElement('div');wrap.className='table-wrap';
    const headers=$$('thead th',table).map(x=>x.textContent.trim());
    $$('tbody tr',table).forEach(tr=>[...tr.cells].forEach((td,i)=>{td.dataset.label=headers[i]||'';const v=document.createElement('span');v.className='cv';v.append(...td.childNodes);td.append(v);}));
    wrap.dataset.cols=headers.length;wrap.innerHTML='<div class="tscroll"></div>';wrap.firstChild.append(table);node=wrap;
  }
  const fences=tokens.filter(t=>t.type==='fence'||t.type==='code_block');
  const diagrams=$$('figure.diagram',node);if(node.matches('figure.diagram'))diagrams.unshift(node);
  fences.filter(t=>isMermaidInfo(t.info)).forEach((t,i)=>{if(diagrams[i])diagrams[i]._mermaid=t.content;});
  const codes=$$('.code',node);if(node.matches('.code'))codes.unshift(node);
  const blockStart=tokens.find(t=>t.map)?.map[0]??0;
  fences.filter(t=>!isMermaidInfo(t.info)).forEach((t,i)=>{if(codes[i]) {
    codes[i]._code=t.content;codes[i]._linePoints=textLinePoints($('pre code',codes[i]));
    codes[i]._lineOffset=(t.map?.[0]??blockStart)-blockStart+1;
  }});
  node._linePoints=textLinePoints(node.matches('.code')?$('pre code',node):node,!node.matches('.code'));
  return node;
}

function reconcile(tokens, fm) {
  const previous=new Map();
  for(const b of S.blocks) {if(!previous.has(b._signature))previous.set(b._signature,[]);previous.get(b._signature).push(b);}
  const blocks=[];let changed=0;
  if(fm) {
    const sig='frontmatter:'+fm[0];let b=previous.get(sig)?.shift();
    if(!b) {b=renderFrontmatter(fm[1]);changed++;}
    b._signature=sig;b._lineBase=2;b._frontmatterRows=$$('dt',b);b.dataset.ls=1;b.dataset.le=fm[0].split('\n').length-1;blocks.push(b);
  }
  for(const group of groups(tokens)) {
    const sig=signature(group);let b=previous.get(sig)?.shift();
    const map=group.find(t=>t.map)?.map;
    if(!b) {
      const template=document.createElement('template');template.innerHTML=sanitize(md.renderer.render(group,md.options,{}));
      if(template.content.children.length===1) b=template.content.firstElementChild;
      else {b=document.createElement('div');b.append(template.content);}
      b=prepareBlock(b,group);b._signature=sig;changed++;
    }
    b.dataset.ls=map?map[0]+1:S.lines;b.dataset.le=map?map[1]:S.lines;b._lineBase=+b.dataset.ls;
    for(const code of [...(b.matches('.code')?[b]:[]),...$$('.code',b)])if(Number.isFinite(code._lineOffset))code._sourceLineStart=b._lineBase+code._lineOffset;
    blocks.push(b);
  }
  // Insert only displaced/new nodes. Unchanged nodes never detach, preserving selection.
  const kept=new Set(blocks);for(const child of [...article.children])if(!kept.has(child))child.remove();
  let at=article.firstChild;
  for(const b of blocks) {
    if(b===at) at=at.nextSibling;else article.insertBefore(b,at);
  }
  while(at) {const next=at.nextSibling;at.remove();at=next;}
  S.blocks=blocks;
  return changed;
}
function buildHeadings(tokens) {
  S.heads=[];const stack=[];S.tree=[];
  for(let i=0;i<tokens.length;i++) {
    const t=tokens[i];if(t.type!=='heading_open') continue;
    const h={level:+t.tag.slice(1),text:plain(tokens[i+1]),slug:t.attrGet('id'),line:t.map[0]+1,tasks:0,done:0,children:[]};
    while(stack.length && stack.at(-1).level>=h.level)stack.pop();
    (stack.length?stack.at(-1).children:S.tree).push(h);stack.push(h);S.heads.push(h);
  }
  S.heads.forEach((h,i)=>{
    const end=S.heads.slice(i+1).find(x=>x.level<=h.level)?.line||S.lines+1;
    for(const b of S.blocks) if(+b.dataset.ls>=h.line&&+b.dataset.ls<end) {
      const boxes=$$('input[type="checkbox"]',b);h.tasks+=boxes.length;h.done+=boxes.filter(x=>x.checked).length;
    }
  });
}

const activeScroller=()=>S.mode==='source'?srcScroller:scroller;
const topIn=(el,sc=scroller)=>el.getBoundingClientRect().top-sc.getBoundingClientRect().top+sc.scrollTop;
function firstTextOrigin(block) {
  const walker=document.createTreeWalker(block,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.textContent.trim()&&!n.parentElement.closest('svg,button,.code-head,figcaption,.katex-mathml')?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT});
  let n;
  while((n=walker.nextNode())) {
    const range=document.createRange();range.selectNodeContents(n);
    const rect=[...range.getClientRects()].find(x=>x.height);if(rect)return rect.top;
  }
  return null;
}
function lineOrigin(line,block=null,sc=activeScroller()) {
  if(S.mode==='source') {const row=$(`.sl[data-line="${line}"]`,source);return row?topIn(row,sc):sc.scrollTop;}
  if(!block)block=S.blocks.find(x=>+x.dataset.ls<=line&&+x.dataset.le>=line)||S.blocks.find(x=>+x.dataset.ls>=line)||S.blocks.at(-1);
  if(!block)return sc.scrollTop;
  if(block.matches('.frontmatter')) {
    if(line<=+block.dataset.ls)return topIn(block,sc);
    const row=block._frontmatterRows?.find(x=>+x.dataset.sourceLine===line);if(row)return topIn(row,sc);
    if(line>+block.dataset.le)return topIn(block,sc)+block.offsetHeight;
  }
  const codes=[...(block.matches('.code')?[block]:[]),...$$('.code',block)];
  const code=codes.find(x=>line>=x._sourceLineStart&&line<x._sourceLineStart+(x._linePoints?.length||0));
  if(code) {
    const index=line-code._sourceLineStart,point=code._linePoints[index],top=pointTop($('pre code',code),point,sc);
    if(top!==null)return top;
  } else if(block.matches('.code')) {
    if(line<block._sourceLineStart)return topIn(block,sc);
    if(line>=block._sourceLineStart+(block._linePoints?.length||0))return topIn(block,sc)+block.offsetHeight;
  }
  const base=block._lineBase||+block.dataset.ls,points=block._linePoints,index=line-base;
  if(index>=0&&index<points?.length) {
    const top=pointTop(block,points[index],sc);if(top!==null)return top;
  }
  return estimateLineOrigin(line,block,sc);
}
function estimateLineOrigin(line,block,sc) {
  const start=+block.dataset.ls,end=Math.max(start,+block.dataset.le),span=end-start+1,index=clamp(line,start,end)-start;
  const top=topIn(block,sc),first=firstTextOrigin(block),origin=first===null?top:first-sc.getBoundingClientRect().top+sc.scrollTop;
  if(span<=1)return origin;
  return origin+Math.max(0,top+(block.offsetHeight||1)-origin)*index/(span-1);
}
function firstTextAt(block,y) {
  // A character anchor holds a real rendered text row through metric changes.
  const walker=document.createTreeWalker(block,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.textContent.trim()&&!n.parentElement.closest(lineMapSkip)?NodeFilter.FILTER_ACCEPT:NodeFilter.FILTER_REJECT});
  let n;
  while((n=walker.nextNode())) {
    const range=document.createRange();range.selectNodeContents(n);const r=range.getBoundingClientRect();
    if(!r.height||r.bottom<y)continue;
    let lo=0,hi=n.length;
    while(lo<hi) {const mid=(lo+hi)>>1;range.setStart(n,mid);range.setEnd(n,Math.min(mid+1,n.length));if(range.getBoundingClientRect().bottom<=y)lo=mid+1;else hi=mid;}
    if(lo>=n.length)continue;
    range.setStart(n,lo);range.setEnd(n,Math.min(lo+1,n.length));
    const path=[];for(let x=n;x!==block;x=x.parentNode)path.unshift([...x.parentNode.childNodes].indexOf(x));
    return {node:n,path,offset:lo,dy:range.getBoundingClientRect().top-y,text:n.textContent.slice(lo,lo+32)};
  }
  return null;
}
function capture() {
  const sc=activeScroller();if(sc.scrollTop<1)return {atTop:true,line:1};
  if(S.mode==='source') {
    const rows=$$('.sl',source), row=rows.find(x=>topIn(x,sc)+x.offsetHeight>sc.scrollTop)||rows.at(-1);
    return row?{line:+row.dataset.line,dy:topIn(row,sc)-sc.scrollTop,lineOffset:sc.scrollTop-topIn(row,sc),source:true}:null;
  }
  const b=S.blocks.find(x=>topIn(x)+x.offsetHeight>sc.scrollTop)||S.blocks.at(-1);if(!b)return null;
  const text=firstTextAt(b,sc.getBoundingClientRect().top);
  const line=lineAtY(b,sc.scrollTop,sc)??lineForText(b,text)??+b.dataset.ls,origin=lineOrigin(line,b,sc);
  return {block:b,signature:b._signature,occurrence:S.blocks.filter(x=>x._signature===b._signature).indexOf(b),
    line,lineOffset:sc.scrollTop-origin,dy:topIn(b)-sc.scrollTop,frac:clamp((sc.scrollTop-topIn(b))/(b.offsetHeight||1),0,1),text};
}
function restore(a) {
  if(!a)return;
  const sc=activeScroller();if(a.atTop){sc.scrollTop=0;return;}
  if(S.mode==='source') {
    const row=$(`.sl[data-line="${clamp(a.line,1,S.lines)}"]`,source);if(row) {
      const offset=Number.isFinite(a.lineOffset)?a.lineOffset:a.source?-(a.dy||0):0;
      sc.scrollTop=topIn(row,sc)+offset;
    }
    return;
  }
  let b=a.block?.isConnected?a.block:S.blocks.filter(x=>x._signature===a.signature)[a.occurrence||0];
  if(a.source) {
    const origin=lineOrigin(clamp(a.line,1,S.lines),null,sc);
    const offset=Number.isFinite(a.lineOffset)?a.lineOffset:-(a.dy||0);
    sc.scrollTop=origin+offset;return;
  }
  const same=!!b;
  b ||= S.blocks.find(x=>+x.dataset.ls<=a.line&&+x.dataset.le>=a.line)||S.blocks.find(x=>+x.dataset.ls>=a.line)||S.blocks.at(-1);
  if(!b)return;
  if(same && a.text) {
    let n=b;for(const i of a.text.path)n=n?.childNodes[i];
    if(n?.nodeType===Node.TEXT_NODE&&a.text.offset<n.length) {
      const r=document.createRange();r.setStart(n,a.text.offset);r.setEnd(n,a.text.offset+1);
      sc.scrollTop+=r.getBoundingClientRect().top-sc.getBoundingClientRect().top-a.text.dy;return;
    }
  }
  sc.scrollTop=topIn(b)-(a.source?0:a.dy||0);
}
function hold(fn) {const a=capture();fn();layoutAll();restore(a);publish();}
function resolvedTheme() {return C11MD.get(S.theme==='system'?(S.os||(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark')):S.theme);}
function applyTheme() {
  const t=resolvedTheme();S.resolved=t.id;S.face=S.typeface==='theme'?t.faceDef.id:S.typeface;
  C11MD.apply(t.id,t.id,S.typeface==='theme'?null:S.face);
  surface.style.setProperty('--scale',S.scale);
  surface.dataset.mode=S.mode;
  $('#diagramClose').textContent=S.strings.close;
}
function layoutAll() {
  const width=surface.clientWidth, effective=width/S.scale;
  S.size=effective<620?'narrow':effective<1000?'medium':'wide';surface.dataset.size=S.size;surface.dataset.tight=effective<430?'1':'0';
  surface.style.setProperty('--scroll-h',scroller.clientHeight+'px');surface.style.setProperty('--dmax',Math.floor(surface.clientHeight*.85)+'px');
  const font=parseFloat(getComputedStyle(col).fontSize), measure=parseFloat(getComputedStyle(surface).getPropertyValue('--face-measure'))*font;
  const notes=!!article.querySelector('.footnotes');
  const margin=notes && width>=measure+222*S.scale+64*S.scale;
  layout.classList.toggle('with-sn',margin);
  const panel=272*S.scale, gap=28*S.scale, right=32*S.scale;
  S.docked=width>=panel+gap+measure+(margin?222*S.scale:0)+right;
  S.outlineOpen=S.outlineChoice==='auto'?S.docked:S.outlineChoice;
  // Reserve the dock regardless of visibility; closing the outline never shifts text.
  layout.style.paddingLeft=S.docked?(panel+gap)+'px':'';
  layout.style.paddingRight='';
  const colR=col.getBoundingClientRect(), layR=layout.getBoundingClientRect();
  const padL=parseFloat(getComputedStyle(layout).paddingLeft)||0,padR=parseFloat(getComputedStyle(layout).paddingRight)||0;
  const left=Math.max(0,colR.left-layR.left-padL), rightSpace=margin?0:Math.max(0,layR.right-padR-colR.right);
  for(const wrap of $$('.table-wrap',article)) {
    wrap.classList.remove('reflow','scrolls');wrap.style.marginLeft=wrap.style.marginRight='';
    if(S.size==='narrow'&&+wrap.dataset.cols>=3) {wrap.classList.add('reflow');continue;}
    wrap.classList.add('measure');const natural=wrap.querySelector('table').offsetWidth;wrap.classList.remove('measure');
    const extra=Math.min(Math.max(0,natural-colR.width),left+rightSpace);const l=Math.min(left,extra/2),r=Math.min(rightSpace,extra-l);
    wrap.style.marginLeft=-l+'px';wrap.style.marginRight=-r+'px';
    const sc=wrap.querySelector('.tscroll');wrap.classList.toggle('scrolls',sc.scrollWidth>sc.clientWidth+1);
  }
  placeNotes();
}
function placeNotes() {
  const aside=$('#sidenotes');aside.replaceChildren();if(!layout.classList.contains('with-sn'))return;
  let bottom=20;
  for(const li of $$('.footnotes li[data-fn]',article)) {
    const ref=$(`.fn-ref a[data-fn="${li.dataset.fn}"]`,article);if(!ref)continue;
    const note=document.createElement('div');note.className='sidenote';note.dataset.fn=li.dataset.fn;
    const body=li.cloneNode(true);$$('.fn-back',body).forEach(x=>x.remove());
    note.innerHTML=`<span class="sn">${esc(li.dataset.fn)}</span>`+body.innerHTML.replace(/^\s*<p>|<\/p>\s*$/g,'');
    aside.append(note);const y=Math.max(bottom,ref.getBoundingClientRect().top-col.getBoundingClientRect().top);note.style.top=y+'px';bottom=y+note.offsetHeight+18;
  }
}
function buildSource() {
  const frag=document.createDocumentFragment();
  S.markdown.split('\n').forEach((line,i)=>{const row=document.createElement('div');row.className='sl';row.dataset.line=i+1;
    const num=document.createElement('span');num.className='n';num.textContent=i+1;const text=document.createElement('span');text.className='t';text.textContent=line||'\u200b';
    if(/^#{1,6}\s/.test(line))text.classList.add('s-h');row.append(num,text);frag.append(row);});
  source.replaceChildren(frag);
}
function configureMermaid() {
  const t=resolvedTheme(),c=t.mermaid;
  mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,theme:'base',
    // Document directives cannot override this allowlist or enable HTML labels.
    secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','flowchart','htmlLabels','theme','themeVariables'],
    maxTextSize:50000,maxEdges:500,htmlLabels:false,
    fontFamily:'"JetBrains Mono Variable", monospace',flowchart:{htmlLabels:false,curve:'basis',padding:14,nodeSpacing:34,rankSpacing:46},
    sequence:{actorMargin:46,boxMargin:8,mirrorActors:false,messageFontSize:12,noteFontSize:12,actorFontSize:12},
    themeVariables:{darkMode:t.scheme==='dark',background:c.bg,fontSize:'12.5px',primaryColor:c.node,primaryTextColor:c.text,primaryBorderColor:c.border,
      secondaryColor:c.cluster,tertiaryColor:c.cluster,lineColor:c.line,textColor:c.text,mainBkg:c.node,nodeBorder:c.border,nodeTextColor:c.text,
      clusterBkg:c.cluster,clusterBorder:c.clusterB,titleColor:c.text,edgeLabelBackground:c.bg,actorBkg:c.node,actorBorder:c.border,actorTextColor:c.text,actorLineColor:c.clusterB,
      signalColor:c.line,signalTextColor:c.text,labelBoxBkgColor:c.node,labelBoxBorderColor:c.border,labelTextColor:c.text,loopTextColor:c.text,
      noteBkgColor:c.note,noteTextColor:c.noteT,noteBorderColor:c.noteB,activationBkgColor:c.act,activationBorderColor:c.border}});
}
function diagramSource(raw) {
  // Decode entities before Mermaid sees semicolons, especially in sequence messages.
  // Mermaid's native #name; form represents literal angle brackets safely in labels.
  const decoded=raw.replace(/&(?:lt|gt|amp|quot|apos|#\d+|#x[\da-f]+);/gi,m=>{
    const el=document.createElement('textarea');el.innerHTML=m;return el.value;
  });
  const initDirective=/^\s*%%\s*\{\s*init\s*:/im.test(decoded);
  const frontmatter=/^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)/.exec(decoded);
  const configFrontmatter=!!frontmatter&&/^\s*config\s*:/im.test(frontmatter[1]);
  if(initDirective||configFrontmatter)throw new Error('Unsupported diagram directive');
  return raw.replace(/&(lt|gt|amp|quot|apos|#\d+|#x[\da-f]+);/gi,(_,name)=>name.startsWith('#x')?'#'+parseInt(name.slice(2),16)+';':name.startsWith('#')?name+';':'#'+name+';');
}
function cleanSVG(svg) {
  const clean=DOMPurify.sanitize(svg,{USE_PROFILES:{svg:true,svgFilters:true},FORBID_TAGS:['foreignObject','image','a','script','iframe'],FORBID_ATTR:['href','xlink:href','src']});
  const template=document.createElement('template');template.innerHTML=clean;
  const el=template.content.querySelector('svg');if(!el)throw new Error('Missing diagram');
  // Mermaid emits CSS, but no CSS capable of reaching another resource may survive.
  for(const style of $$('style',el)) if(/\\|@import|url\s*\((?!\s*['"]?#)/i.test(style.textContent)) style.remove();
  for(const node of [el,...$$('*',el)]) for(const a of [...node.attributes]) {
    if(/^on/i.test(a.name)||a.name==='style'&&/\\/.test(a.value)||/url\s*\((?!\s*['"]?#)/i.test(a.value))node.removeAttribute(a.name);
  }
  el.removeAttribute('height');el.style.width='100%';el.style.maxWidth='100%';return el;
}
async function diagrams(generation) {
  configureMermaid();let n=0;
  for(const fig of $$('figure.diagram',article)) {
    n++;fig.dataset.n=n;$('.cap',fig).textContent=S.strings.diagram+' '+n;
    if(fig._theme===S.resolved)continue;
    if(generation!==S.generation)return;
    const id='c11md-'+generation+'-'+n+'-'+(++diagramRenderId);
    try {
      const {svg}=await mermaid.render(id,diagramSource(fig._mermaid));
      if(generation!==S.generation)return;
      const a=capture();$('.diagram-stage',fig).replaceChildren(cleanSVG(svg));fig._theme=S.resolved;layoutAll();restore(a);
    } catch(e) {
      if(generation!==S.generation)return;
      const a=capture(), box=document.createElement('div');box.className='diagram-err';
      const label=document.createElement('div');label.textContent=S.strings.diagramError;const pre=document.createElement('pre');pre.textContent=fig._mermaid;box.append(label,pre);
      $('.diagram-stage',fig).replaceChildren(box);fig._theme=S.resolved;layoutAll();restore(a);error('diagram_failed',e);
    } finally {document.getElementById('d'+id)?.remove();}
  }
}
let diagramRenderId=0;

function findState() {return {query:S.find.query,matches:S.find.hits.length,current:S.find.index<0?0:S.find.index+1};}
function clearMarks() {
  for(const mark of $$('mark.hit',surface))mark.replaceWith(...mark.childNodes);
  for(const b of S.blocks)b.normalize();source.normalize();S.find.hits=[];S.find.index=-1;
}
function search(query,{keepPlace=false}={}) {
  const a=capture();clearMarks();S.find.query=String(query||'');
  if(!S.find.query){publish();return findState();}
  const roots=S.mode==='source'?$$('.sl .t',source):S.blocks.filter(x=>!x.matches('.footnotes')||!layout.classList.contains('with-sn'));
  const q=S.find.query.toLowerCase();
  for(const root of roots) {
    const nodes=[];let text='';
    const walk=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode:n=>n.parentElement.closest('svg,button,.code-head,figcaption,.katex-mathml')?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_ACCEPT});
    let node;while((node=walk.nextNode())){nodes.push({node,start:text.length,end:text.length+node.length});text+=node.textContent;}
    const lower=text.toLowerCase(), matches=[];let from=0,i;
    while((i=lower.indexOf(q,from))>=0){matches.push([i,i+q.length]);from=i+q.length;}
    const hitGroups=matches.map(()=>[]);
    for(const item of nodes) {
      for(let m=matches.length-1;m>=0;m--) {
        const start=Math.max(item.start,matches[m][0]),end=Math.min(item.end,matches[m][1]);if(start>=end)continue;
        const range=document.createRange();range.setStart(item.node,start-item.start);range.setEnd(item.node,end-item.start);
        const mark=document.createElement('mark');mark.className='hit';range.surroundContents(mark);hitGroups[m].unshift(mark);
      }
    }
    S.find.hits.push(...hitGroups);
  }
  if(S.find.hits.length){S.find.index=0;selectHit(!keepPlace);}
  if(keepPlace)restore(a);publish();return findState();
}
function selectHit(scroll=true) {
  $$('mark.hit.cur',surface).forEach(x=>x.classList.remove('cur'));
  const hit=S.find.hits[S.find.index];if(!hit)return;
  hit.forEach(x=>x.classList.add('cur'));
  if(scroll) {const sc=activeScroller();sc.scrollTop=topIn(hit[0],sc)-Math.min(80,sc.clientHeight*.2);}
}
function nextHit(delta) {if(S.find.hits.length){S.find.index=(S.find.index+delta+S.find.hits.length)%S.find.hits.length;selectHit();}publish();return findState();}
const headingElement=slug=>$$('[data-heading-slug]',article).find(x=>x.dataset.headingSlug===slug);
function currentHeading() {
  const line=S.mode==='source'?visibleLines().first:null;
  let h=null;for(const candidate of S.heads) {
    const el=headingElement(candidate.slug);
    if(line!==null?candidate.line<=line:el&&topIn(el)<=scroller.scrollTop+40)h=candidate;else break;
  }
  return h;
}
function visibleLines() {
  const sc=activeScroller(),top=sc.scrollTop,bottom=top+sc.clientHeight;
  if(S.mode==='source') {
    const rows=$$('.sl',source),visible=rows.filter(x=>topIn(x,sc)+x.offsetHeight>top&&topIn(x,sc)<bottom);
    const firstRow=visible[0];return {first:+firstRow?.dataset.line||1,last:+visible.at(-1)?.dataset.line||1,total:S.lines,
      offset:firstRow?top-topIn(firstRow,sc):0};
  }
  let first=null,last=1,firstBlock=null,firstOffset=0;
  for(const b of S.blocks) {
    const t=topIn(b),height=b.offsetHeight||1;if(t+height<top)continue;if(t>bottom)break;
    const start=+b.dataset.ls,end=+b.dataset.le,span=Math.max(1,end-start+1);
    if(first===null) {
      firstBlock=b;const mapped=lineAtY(b,top,sc);
      if(mapped!==null) {first=mapped;firstOffset=top-lineOrigin(first,b,sc);}
      else {
        const firstOrigin=lineOrigin(start,b,sc),lastOrigin=lineOrigin(end,b,sc);
        first=start+Math.floor(clamp((top-firstOrigin)/Math.max(1,lastOrigin-firstOrigin),0,1)*(span-1));firstOffset=top-lineOrigin(first,b,sc);
      }
    }
    const endText=firstTextAt(b,sc.getBoundingClientRect().bottom-1),endLine=lineForText(b,endText);
    last=endLine===null?Math.min(end,start+Math.ceil(clamp((bottom-t)/height,0,1)*(span-1))):endLine;
  }
  first ||= 1;
  return {first,last:Math.max(first,last),total:S.lines,offset:firstBlock?firstOffset:0};
}
function progress() {
  const sc=activeScroller(),p=clamp(sc.scrollTop/Math.max(1,sc.scrollHeight-sc.clientHeight*1.5),0,1);
  return {progress:p,minutesLeft:Math.max(0,Math.ceil(S.words/230*(1-p)))};
}
function visible() {
  const h=currentHeading(),path=[];
  if(h)for(const x of S.heads){if(x.line>h.line)break;while(path.length&&path.at(-1).level>=x.level)path.pop();path.push(x);}
  const p=progress(),selection=window.getSelection()?.toString().trim();
  return {file:S.file,revision:S.revision,mode:S.mode,pane:{width:surface.clientWidth,effectiveWidth:surface.clientWidth/S.scale,size:S.size},
    heading_path:path.map(x=>x.text),heading:h,lines:visibleLines(),progress:p.progress,minutes_left:p.minutesLeft,
    find:S.find.query?findState():null,outline:{open:S.outlineOpen,docked:S.docked,choice:S.outlineChoice,tree:S.tree},
    theme:{choice:S.theme,resolved:S.resolved},typeface:{choice:S.typeface,resolved:S.face},font_scale:S.scale,
    diagram_open:S.diagram,selection:selection?selection.slice(0,120):null};
}
let stateFrame=0, stableAnchor=null;
function publish() {if(!stateFrame)stateFrame=requestAnimationFrame(()=>{stateFrame=0;stableAnchor=capture();post({type:'state',state:visible()});});}
function enqueue(task,supersedes=true) {
  const generation=supersedes?++S.generation:null;
  const run=async()=>{if(supersedes&&generation!==S.generation)return visible();try {return await task(generation??S.generation);}catch(e){error('render_failed',e);return visible();}};
  const result=S.renderQueue.then(run);S.renderQueue=result.catch(()=>{});return result;
}
async function load(input) {
  if(!input||typeof input.markdown!=='string'||typeof input.documentPath!=='string') {error('invalid_argument','load requires markdown and documentPath');return visible();}
  const doc={...input};
  return enqueue(async generation=>{
    const same=S.file===doc.documentPath,a=same?capture():{atTop:true,line:1};
    if(!same){S.blocks=[];article.replaceChildren();closeDiagram();$('#note').hidden=true;$('#back').hidden=true;}
    const query=S.find.query;if(query)clearMarks();
    S.markdown=doc.markdown.replace(/\r\n?/g,'\n');S.file=doc.documentPath;S.baseURL=doc.baseURL||'';S.revision=doc.revision??null;
    S.lines=S.markdown.split('\n').length;S.words=S.markdown.trim()?S.markdown.trim().split(/\s+/).length:0;
    const {body,fm}=prep(S.markdown),tokens=md.parse(body,{}),changed=reconcile(tokens,fm);
    buildHeadings(tokens);buildSource();applyTheme();layoutAll();restore(a);
    await document.fonts.ready;if(generation!==S.generation)return visible();
    layoutAll();restore(a);await diagrams(generation);if(generation!==S.generation)return visible();
    if(query)search(query,{keepPlace:true});
    layoutAll();publish();post({type:'rendered',revision:S.revision,blocks:S.blocks.length,changedBlocks:changed});return visible();
  });
}
async function setSettings(input={}) {
  const settings={...input};
  return enqueue(async generation=>{
    const a=capture();
    if('theme'in settings)S.theme=settings.theme==='system'||C11MD.get(settings.theme)?settings.theme:'system';
    if('typeface'in settings)S.typeface=settings.typeface==='theme'||C11MD.getFace(settings.typeface)?settings.typeface:'theme';
    if('scale'in settings)S.scale=typeof settings.scale==='number'&&settings.scale>=.5&&settings.scale<=3?settings.scale:1;
    if('outlineOpen'in settings)S.outlineChoice=[true,false,'auto'].includes(settings.outlineOpen)?settings.outlineOpen:'auto';
    if('osAppearance'in settings)S.os=['light','dark'].includes(settings.osAppearance)?settings.osAppearance:null;
    if(settings.strings && typeof settings.strings==='object')for(const k of Object.keys(defaults))if(typeof settings.strings[k]==='string')S.strings[k]=settings.strings[k];
    applyTheme();layoutAll();restore(a);
    await document.fonts.ready;if(generation!==S.generation)return visible();
    layoutAll();restore(a);await diagrams(generation);if(generation!==S.generation)return visible();
    for(const x of $$('.copy',article))x.textContent=S.strings.copy;
    for(const x of $$('.expand',article))x.textContent=S.strings.expand;
    for(const x of $$('.h-anchor',article))x.title=S.strings.copyLink;
    publish();return visible();
  },false);
}
let modeAnchor=null;
function setSourceMode(enabled) {
  const mode=enabled?'source':'read';if(mode===S.mode)return visible();
  const a=capture(),query=S.find.query;clearMarks();
  // An untouched source toggle round-trip restores the exact original text row.
  const restoreTo=mode==='read'&&modeAnchor&&a?.line===modeAnchor.sourceLine&&
    Math.abs((a.lineOffset||0)-modeAnchor.sourceOffset)<=.5?modeAnchor.anchor:a;
  S.mode=mode;applyTheme();layoutAll();restore(restoreTo);
  if(mode==='source') {
    const lines=visibleLines();modeAnchor={anchor:a,sourceLine:lines.first,sourceOffset:lines.offset};
  } else modeAnchor=null;
  if(query)search(query,{keepPlace:true});publish();return visible();
}
function scrollToLine(raw,rawOffset=0) {
  const line=clamp(Math.round(Number(raw)||1),1,S.lines),sc=activeScroller();
  const b=S.mode==='source'?$(`.sl[data-line="${line}"]`,source):S.blocks.find(x=>+x.dataset.ls<=line&&+x.dataset.le>=line)||S.blocks.find(x=>+x.dataset.ls>=line);
  const requestedOffset=Number(rawOffset),offset=Number.isFinite(requestedOffset)?requestedOffset:0;
  if(b)sc.scrollTop=lineOrigin(line,b,sc)+offset;publish();return visible();
}
function scrollToHeading(query) {
  const q=String(query||'').toLowerCase().replace(/^#/,'');
  const h=S.heads.find(x=>x.slug.toLowerCase()===q)||S.heads.find(x=>x.text.toLowerCase()===q)||S.heads.find(x=>x.text.toLowerCase().startsWith(q)&&q)||S.heads.find(x=>x.text.toLowerCase().includes(q)&&q);
  if(!h)return {ok:false,heading:null};
  if(S.mode==='source')setSourceMode(false);
  const el=headingElement(h.slug);if(el){scroller.scrollTop=topIn(el)-18;el.classList.remove('section-flash');void el.offsetWidth;el.classList.add('section-flash');}
  publish();return {ok:true,heading:h};
}
let overlayScale=1;
function expandDiagram(number) {
  const fig=$$('figure.diagram',article).find(x=>+x.dataset.n===+number),svg=fig?.querySelector('svg');if(!svg)return false;
  S.diagram=+number;const copy=svg.cloneNode(true),vb=svg.viewBox.baseVal;
  copy.style.width=(vb.width||svg.getBoundingClientRect().width)+'px';copy.style.height=(vb.height||svg.getBoundingClientRect().height)+'px';
  $('#diagramZoom').replaceChildren(copy);overlayScale=1;$('#diagramZoom').style.transform='';$('#diagramOverlay').hidden=false;
  $('#diagramPan').scrollTop=$('#diagramPan').scrollLeft=0;publish();return true;
}
function closeDiagram() {S.diagram=null;$('#diagramOverlay').hidden=true;$('#diagramZoom').replaceChildren();publish();}

function handleClick(e) {
  if(e.type==='auxclick'&&e.button!==1)return;
  const target=e.target instanceof Element?e.target:null;if(!target)return;
  const a=target.closest('a');if(a)e.preventDefault();
  const copy=target.closest('.copy');if(copy){const b=copy.closest('.code');post({type:'copy',kind:'code',text:b._code||b.querySelector('code')?.textContent||''});copy.textContent=S.strings.copied;return;}
  const heading=target.closest('.h-anchor');if(heading){post({type:'copy',kind:'heading',text:(S.baseURL||S.file).split('#')[0]+'#'+heading.dataset.slug});return;}
  const expand=target.closest('.expand,.diagram-stage');if(expand){expandDiagram(+expand.closest('figure').dataset.n);return;}
  if(!a)return;
  const href=a.getAttribute('href')||'',info=linkInfo(href);
  post({type:'link',href,...info,modifiers:{meta:e.metaKey,ctrl:e.ctrlKey,shift:e.shiftKey,alt:e.altKey}});
  if(info.kind!=='anchor')return;
  let id;try{id=decodeURIComponent(href.slice(1));}catch{return;}
  if(a.closest('.fn-ref')) {
    const note=$(`.footnotes li[data-fn="${a.dataset.fn}"]`,article);if(!note)return;
    if(layout.classList.contains('with-sn')) {const margin=$(`.sidenote[data-fn="${a.dataset.fn}"]`);margin?.classList.toggle('hot');return;}
    const pop=$('#note');pop.innerHTML=note.innerHTML;$$('.fn-back',pop).forEach(x=>x.remove());pop.style.left=clamp(a.getBoundingClientRect().left,12,surface.clientWidth-352)+'px';
    pop.style.top=Math.min(a.getBoundingClientRect().bottom+12,surface.clientHeight*.5)+'px';pop.hidden=false;return;
  }
  const dest=headingElement(id)||$$('[id]',article).find(x=>x.id===id);if(!dest)return;
  const before=capture(),h=currentHeading();scroller.scrollTop=topIn(dest)-18;
  const back=$('#back');back.textContent='↩ '+S.strings.back+' '+(h?.text||S.file.split('/').at(-1));back.hidden=false;back.classList.add('open');
  back.onclick=()=>{restore(before);back.hidden=true;back.classList.remove('open');publish();};publish();
}
surface.addEventListener('click',handleClick);
surface.addEventListener('auxclick',handleClick);
$('#diagramClose').addEventListener('click',closeDiagram);
$$('[data-zoom]').forEach(b=>b.addEventListener('click',()=>{const delta=+b.dataset.zoom;overlayScale=delta?clamp(overlayScale*(delta>0?1.25:.8),.25,5):1;$('#diagramZoom').style.transform=`scale(${overlayScale})`;}));
const pan=$('#diagramPan');let drag=null;
pan.addEventListener('pointerdown',e=>{drag={x:e.clientX,y:e.clientY,left:pan.scrollLeft,top:pan.scrollTop};pan.setPointerCapture(e.pointerId);});
pan.addEventListener('pointermove',e=>{if(drag){pan.scrollLeft=drag.left+drag.x-e.clientX;pan.scrollTop=drag.top+drag.y-e.clientY;}});
pan.addEventListener('pointerup',()=>{drag=null;});pan.addEventListener('pointercancel',()=>{drag=null;});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeDiagram();$('#note').hidden=true;}});
for(const sc of [scroller,srcScroller])sc.addEventListener('scroll',publish,{passive:true});
document.addEventListener('selectionchange',publish);
// Preserve the last settled anchor when an image or pane resize changes layout.
new ResizeObserver(()=>{const a=stableAnchor;layoutAll();restore(a);publish();}).observe(surface);
article.addEventListener('load',()=>{const a=stableAnchor;layoutAll();restore(a);publish();},true);
matchMedia('(prefers-color-scheme: light)').addEventListener('change',()=>{if(S.theme==='system'&&!S.os)setSettings({});});
window.c11md=Object.freeze({load,setSettings,scrollToHeading,scrollToLine,visible,outline:()=>S.tree,progress,
  find:query=>search(query),findNext:()=>nextHit(1),findPrevious:()=>nextHit(-1),findClose:()=>search(''),setSourceMode,expandDiagram,closeDiagram,
  themes:()=>[{id:'system',label:'system',scheme:'system',defaultTypeface:'serif'},...C11MD.themes.map(t=>({id:t.id,label:t.label,scheme:t.scheme,defaultTypeface:t.faceDef.id}))],
  typefaces:()=>[{id:'theme',label:'theme default',family:'theme',measure:null,leading:null},...C11MD.faces.map(f=>({id:f.id,label:f.label,family:f.family,measure:parseFloat(f.tokens['--face-measure']),leading:+f.tokens['--face-lh']}))]});
applyTheme();layoutAll();document.fonts.ready.then(()=>{post({type:'ready',version:1});publish();});
})();
