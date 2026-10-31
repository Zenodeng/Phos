(() => {
  if (!new URLSearchParams(location.search).has('audit')) return;
  const output=document.createElement('output');output.id='site-audit';output.hidden=true;document.body.append(output);
  let lcp=null,cls=null;
  const supported=PerformanceObserver.supportedEntryTypes||[];
  function report(){
    const resources=performance.getEntriesByType('resource').filter(r=>/^https?:/.test(r.name)&&!r.name.includes('audit-metrics.js'));
    const nav=performance.getEntriesByType('navigation')[0];
    const text=[...document.querySelectorAll('body *')].filter(e=>e!==output&&e.namespaceURI==='http://www.w3.org/1999/xhtml'&&[...e.childNodes].some(n=>n.nodeType===3&&n.textContent.trim())&&e.getBoundingClientRect().width&&e.getBoundingClientRect().height);
    const sizes=[...new Set(text.map(e=>getComputedStyle(e).fontSize))].sort((a,b)=>parseFloat(a)-parseFloat(b));
    const h=document.querySelector('h1'),hStyle=h&&getComputedStyle(h);
    output.dataset.report=JSON.stringify({url:location.href,width:innerWidth,height:innerHeight,scroll:scrollY,pageWidth:document.documentElement.scrollWidth,pageHeight:document.documentElement.scrollHeight,readableSizes:sizes,minReadable:Math.min(...sizes.map(parseFloat)),h1Lines:h?Math.round(h.getBoundingClientRect().height/parseFloat(hStyle.lineHeight)):null,h1Font:hStyle?.fontFamily,h2Count:document.querySelectorAll('h2').length,mainH2Lines:[...document.querySelectorAll('main h2')].filter(h=>h.getBoundingClientRect().height).map(h=>({text:h.textContent.trim(),lines:Math.round(h.getBoundingClientRect().height/parseFloat(getComputedStyle(h).lineHeight))})),requests:resources.length+1,encodedBytes:resources.reduce((s,r)=>s+r.encodedBodySize,nav?.encodedBodySize||0),fonts:resources.filter(r=>/\.(woff2?|ttf|otf)(\?|$)/.test(r.name)).map(r=>({name:r.name,bytes:r.encodedBodySize})),largestResource:resources.map(r=>({name:r.name,bytes:r.encodedBodySize})).sort((a,b)=>b.bytes-a.bytes).slice(0,4),LCP:lcp,CLS:cls,supportedPaintMetrics:supported.filter(t=>['largest-contentful-paint','layout-shift'].includes(t)),body:getComputedStyle(document.querySelector('.look-card>p,.feature-chapter li,.help-main p')||document.body).fontSize,resources:resources.map(r=>({name:r.name,bytes:r.encodedBodySize}))});
  }
  if(supported.includes('largest-contentful-paint'))new PerformanceObserver(list=>{lcp=list.getEntries().at(-1).startTime;report();}).observe({type:'largest-contentful-paint',buffered:true});
  if(supported.includes('layout-shift')){cls=0;new PerformanceObserver(list=>{for(const e of list.getEntries())if(!e.hadRecentInput)cls+=e.value;report();}).observe({type:'layout-shift',buffered:true});}
  if(supported.includes('resource'))new PerformanceObserver(report).observe({type:'resource',buffered:true});
  function loaded(){output.dataset.loaded='true';report();}if(document.readyState==='complete')loaded();else addEventListener('load',loaded);addEventListener('resize',report);document.fonts.ready.then(()=>{report();output.dataset.ready='true';});report();
})();
